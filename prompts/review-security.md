Security. You own trust boundaries; correctness and UI belong to the other
reviewers. Look for:

- **Authorization**: every new or changed endpoint, query, job and webhook
  checks who is asking and scopes data to them. Tenant isolation (row-level
  security, an `org_id`/`tenant_id` filter, ownership checks) must hold on
  reads, writes and deletes, including list endpoints and background jobs that
  run without a request user.
- **Authentication**: new routes are behind the same guard as their
  neighbours unless they are deliberately public; tokens, sessions and
  password-reset/invite flows expire and are single-use where they should be.
- **Injection**: SQL built from strings, raw query helpers, shell commands,
  template rendering of user input, path traversal in file names, open
  redirects, SSRF through user-supplied URLs.
- **Input validation** at the boundary: request DTOs/schemas cover new fields;
  mass assignment of fields a user must not set (role, owner, price, status).
- **Secrets and data exposure**: keys or tokens in code, logs, error messages
  or client bundles; responses that return more fields than the caller may
  see; PII written to logs or analytics.
- **Third-party callbacks**: webhook signature verification, idempotency,
  replay; payment amounts and plans taken from the server, never the client.
- **Crypto and randomness**: home-made crypto, `Math.random` for tokens,
  timing-unsafe comparisons of secrets.

An exploitable path to another tenant's data, to privilege escalation or to a
secret is a `blocker`. A missing check that is not reachable today is `major`.
