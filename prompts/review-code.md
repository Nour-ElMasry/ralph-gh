Code correctness and maintainability. Security and UI belong to the other
reviewers. Look for:

- **Logic errors**: wrong conditions, off-by-one, inverted checks, wrong
  units, mishandled null/empty/zero, time zones, money as floats.
- **Failure handling**: errors swallowed, partial writes without a
  transaction, retries that are not idempotent, missing cleanup, promises not
  awaited.
- **Concurrency**: races between requests or jobs, check-then-act on shared
  rows, cache invalidation that leaves stale data.
- **Data changes**: migrations that lose data, are not reversible when the
  repo's other migrations are, or lock large tables; schema and code that
  disagree.
- **Contracts**: callers of a changed function, type or API that were not
  updated; a breaking API change without the matching client change.
- **Tests**: new behaviour with no test that exercises it, tests that assert
  nothing meaningful, mocks that hide the behaviour under test.
- **Design**: duplication of an existing helper, dead code, or complexity
  the change does not need. These are `minor` unless they hide a defect.

A defect that breaks a core flow or loses data is a `blocker`; any other real
defect is `major`.
