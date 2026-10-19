#!/usr/bin/env python3
"""Redact credentials from QA evidence before it leaves the machine.

QA evidence is pushed to a branch of the product repo, and a QA turn's curl
transcripts, Playwright response dumps, Mailpit messages and traces carry the
stack's session cookies, CSRF tokens, JWTs, API keys and one-time links. They
are tokens for a throwaway local stack, but they are still credentials, and a
history secret scan that walks every ref reads them as leaks.

    qa_redact.py <dir>     redact every file under <dir> in place, zips included
    qa_redact.py --stdin   filter stdin to stdout (report text, bug bodies)

Values are replaced, names are kept: `Set-Cookie: access_token=<redacted>;
HttpOnly; Secure` still proves the cookie's flags. Binary files are left alone,
except .zip archives (Playwright traces), whose text members are redacted and
the archive rewritten. A zip that cannot be read is deleted rather than
published unread. Exit 0 on success; non-zero means the directory must not be
published.
"""

import os
import re
import sys
import tempfile
import zipfile

R = "<redacted>"

# Request and response headers whose value is a credential.
HEADER_NAMES = (
    r"authorization|proxy-authorization|cookie|set-cookie|x-csrf-token|x-xsrf-token"
    r"|x-api-key|x-form-session|x-form-submission|x-form-unlock"
)
# Field, parameter and cookie names whose value is a credential. Matched at the
# end of the name, so `XSRF-TOKEN`, `refreshToken` and `STRIPE_SECRET_KEY` hit
# and `tokenExpiresAt` does not.
SECRET_NAME = (
    r"[A-Za-z0-9_.-]*?(?:token|secret|password|passwd|passkey|api[_-]?key|raw[_-]?key|refund[_-]?key"
    r"|secret[_-]?key|private[_-]?key|access[_-]?key|oauth[_-]?state|credentials?)"
)

# A token starts at a non-word character or right after a percent escape:
# `%22pk_test_…` and `%3Deyj…` sit inside URL-encoded query strings.
START = r"(?:(?<=%[0-9A-Fa-f]{2})|(?<![A-Za-z0-9_-]))"

JWT = re.compile(START + r"ey[A-Za-z0-9_-]{8,}\.ey[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*")
KNOWN_SHAPES = [
    (re.compile(START + r"(?:sk|rk)_(?:test|live)_[A-Za-z0-9]{10,}"), "<redacted:stripe-key>"),
    (re.compile(START + r"whsec_[A-Za-z0-9+/=]{16,}"), "<redacted:whsec>"),
    # Publishable keys are public by design, but a history scan reads one as a
    # key, and Stripe.js resources inside a trace carry them by the hundred.
    (re.compile(START + r"pk_(?:test|live)_[A-Za-z0-9]{10,}"), "<redacted:stripe-publishable-key>"),
    (re.compile(START + r"hp_[0-9a-f]{32,}"), "<redacted:api-key>"),
]
# `"cookie": "…"` in a JSON headers object (Playwright response dumps).
JSON_HEADER = re.compile(r'(?i)("(?:' + HEADER_NAMES + r')"\s*:\s*")((?:[^"\\]|\\.)*)(")')
# `{"name": "cookie", "value": "…"}` in a headers array (Playwright traces, HAR).
NAME_VALUE_HEADER = re.compile(
    r'(?i)("name"\s*:\s*"(?:' + HEADER_NAMES + r')"\s*,\s*"value"\s*:\s*")((?:[^"\\]|\\.)*)(")'
)
# `Cookie: …` in a curl transcript or a `-H '…'` argument.
TEXT_HEADER = re.compile(r"(?im)\b(" + HEADER_NAMES + r")(\s*:\s*)([^\r\n\"'\\]+)")
# A Netscape cookie jar line (curl -c): the seventh field is the value.
COOKIE_JAR_LINE = re.compile(
    r"(?m)^((?:#HttpOnly_)?[^\t\r\n#][^\t\r\n]*\t(?:TRUE|FALSE)\t[^\t\r\n]*\t(?:TRUE|FALSE)\t\d+\t[^\t\r\n]+\t)[^\t\r\n]+$"
)
JSON_SECRET_FIELD = re.compile(r'(?i)(\\?"' + SECRET_NAME + r'\\?"\s*:\s*\\?")([^"\\\s]{8,})')
# `name=value` in a URL, a form body or a cookie, and `name%3Dvalue` in a URL
# nested inside another one's query string (`returnUrl=…%3Ftoken%3D…`).
PARAM_SECRET = re.compile(r"(?i)(?<![A-Za-z0-9_])(" + SECRET_NAME + r")(=|%3D)([^\s\"'&;,<>\\)%]{8,})")
SCHEME_CREDENTIAL = re.compile(r"\b(Bearer|Basic)\s+([A-Za-z0-9._~+/=-]{8,})")
# `%22token%22%3A%22…` — JSON URL-encoded into a query string (Stripe.js iframes).
ENCODED_JSON_SECRET_FIELD = re.compile(r"(?i)(%22" + SECRET_NAME + r"%22%3A%22)([^%&\"'\s]{8,})")
# `curl -u <user:password>`, a shell expansion included: `-u "$STRIPE_SECRET_KEY:"`
# names no secret, but a history scan cannot tell it from one.
CURL_USER = re.compile(r"((?:\s-u|--user)\s+[\"']?)([^\s\"']+)")


def redact_cookie_pairs(value, first_only):
    """Blank each `name=value` of a Cookie header, or the leading pair of a Set-Cookie."""
    if first_only:
        lines = re.split(r"(\\n|\n)", value)
        return "".join(re.sub(r"^(\s*[^=;\s]+=)[^;]*", r"\1" + R, part, count=1) for part in lines)
    return re.sub(r"((?:^|;)\s*[^=;\s]+=)[^;]*", r"\1" + R, value)


def redact_header_value(name, value):
    lowered = name.lower()
    if lowered == "cookie":
        return redact_cookie_pairs(value, first_only=False)
    if lowered == "set-cookie":
        return redact_cookie_pairs(value, first_only=True)
    scheme = re.match(r"(\s*(?:Bearer|Basic|Token)\s+)", value, re.IGNORECASE)
    return (scheme.group(1) if scheme else "") + R


def header_name_of(match_text):
    return re.search(HEADER_NAMES, match_text, re.IGNORECASE).group(0)


def redact_text(text):
    text = JWT.sub("<redacted:jwt>", text)
    for pattern, replacement in KNOWN_SHAPES:
        text = pattern.sub(replacement, text)
    for pattern in (JSON_HEADER, NAME_VALUE_HEADER):
        text = pattern.sub(
            lambda m: m.group(1) + redact_header_value(header_name_of(m.group(1)), m.group(2)) + m.group(3),
            text,
        )
    text = TEXT_HEADER.sub(
        lambda m: m.group(1) + m.group(2) + redact_header_value(m.group(1), m.group(3)), text
    )
    text = COOKIE_JAR_LINE.sub(lambda m: m.group(1) + R, text)
    text = JSON_SECRET_FIELD.sub(lambda m: m.group(1) + R, text)
    text = ENCODED_JSON_SECRET_FIELD.sub(lambda m: m.group(1) + R, text)
    text = PARAM_SECRET.sub(lambda m: m.group(1) + m.group(2) + R, text)
    text = SCHEME_CREDENTIAL.sub(lambda m: m.group(1) + " " + R, text)
    text = CURL_USER.sub(lambda m: m.group(1) + R, text)
    return text


def is_binary(data):
    return b"\0" in data[:8192]


def redact_bytes(data):
    """Redacted bytes, or None when the content is binary or unchanged."""
    if is_binary(data):
        return None
    text = data.decode("utf-8", errors="surrogateescape")
    redacted = redact_text(text)
    if redacted == text:
        return None
    return redacted.encode("utf-8", errors="surrogateescape")


def redact_zip(path):
    with zipfile.ZipFile(path) as source:
        members = [(info, source.read(info)) for info in source.infolist()]
    changed = False
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".zip")
    os.close(fd)
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as target:
            for info, data in members:
                redacted = redact_bytes(data)
                if redacted is not None:
                    changed = True
                    data = redacted
                target.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED)
        if changed:
            os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return changed


def redact_dir(root):
    changed = 0
    for directory, _, files in os.walk(root):
        for name in files:
            path = os.path.join(directory, name)
            if os.path.islink(path):
                os.remove(path)
                continue
            if name.lower().endswith(".zip"):
                try:
                    changed += redact_zip(path)
                except (zipfile.BadZipFile, OSError, RuntimeError) as error:
                    print(f"qa_redact: {path}: unreadable archive, not published ({error})", file=sys.stderr)
                    os.remove(path)
                continue
            with open(path, "rb") as handle:
                data = handle.read()
            redacted = redact_bytes(data)
            if redacted is not None:
                with open(path, "wb") as handle:
                    handle.write(redacted)
                changed += 1
    print(f"qa_redact: redacted credentials in {changed} file(s) under {root}", file=sys.stderr)


def main(argv):
    if argv == ["--stdin"]:
        data = sys.stdin.buffer.read()
        sys.stdout.buffer.write(redact_bytes(data) or data)
        return 0
    if len(argv) == 1 and os.path.isdir(argv[0]):
        redact_dir(argv[0])
        return 0
    print("usage: qa_redact.py <dir> | --stdin", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
