<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# Roadmap

What has shipped, what is open, and what was declined. Drawn on 2026-09-09 from
`git log --oneline` and `gh issue list --state all`, not from intentions, so a
reader can trust the "shipped" column without checking the log. Issue #36 asked
for this page because the board carries 20 open items with no statement of
which come first. Numbers in parentheses are GitHub issues on
`udin-io/ash_introspection`.

## Shipped

### 0.3.0 — 2026-09-09

A security release, then the breaking change it forced. Every entry below is a
merged commit on `main`.

| Change | Issue | Commit |
|---|---|---|
| Reject non-scalar identity and `get_by` values before the trusted filter | #8 | `d620772` |
| Redact `ForbiddenField` and `NotLoaded` in `normalize_primitive/1` | #9 | `02c067d` |
| Stop minting atoms from client-supplied field names | #10 | `1ff1746` |
| Stop leaking policy breakdowns and exception messages in RPC errors | #11 | `cf75720` |
| Fail closed when a configured error handler crashes | #12 | `c77a61b` |
| JSON-safe serialization for RPC error payloads | #13 | `0126dca` |
| Preserve `false` in plain map fields and named identity filters | #15 | `96a6ad3` |
| Raise the `ash` floor to `~> 3.33`, clearing 22 advisories | #28 | `966f1d6` |
| Teach the formatter about the Ash and Spark DSLs | #30 | `c4a4448` |
| CI: format check, warnings-as-errors, tests, `hex.audit`, `deps.audit` | #32 | `2aa858b` |
| Unify error payloads on `type` and ship `mix ash_introspection.upgrade` | #14, #34 | `b273f70` |

### Earlier

- **0.2.0 — 2025-12-21.** Action introspection, validation error types, the
  README's integration guide.
- **0.1.0 — 2025-11-25.** The extraction from `ash_typescript`: type system,
  four-stage RPC pipeline, field processing, error handling, type discovery.

## In progress

Nothing is on a branch. The board is open work, not started work.

## Next

Ordered by what unblocks the most. #23 is first because it gates roughly a
dozen other items.

1. **#23 — adopt `Ash.Info.Manifest`.** Upstream replaced live introspection
   with a precomputed Spark manifest in `ash` 3.32.3. This repo still calls
   `Ash.Resource.Info` at ~66 sites, which is why upstream's type-discovery
   fixes do not port cleanly. Blocks #19, #20, #21, #22, #24, #25, #26 and more.
2. **Correctness fixes that need no manifest**: #49 (bare
   `function_exported?/3` gives a false negative on a cold VM), #40 (second
   `rescue` in `process_single_error` has no `catch` clause), #44 (reads
   silently ignore the `identity` param), #35 (tuple nested selection keys its
   template from the raw wire name), #16 (a list of errors in
   `build_error_response/1` for bulk actions), #17 (unwrap Reactor step errors,
   serialize `Ash.Type.Vector`).
3. **#18 — the RPC test floor.** Coverage arrives with each fix by preference,
   but the harness and the fixtures are still a ticket of their own.
4. **Upstream parity features**: #19 (load restrictions), #24 (relationship
   query envelopes), #25 (calculation load-through and nested first-aggregates),
   #26 (persist formatted field names via a Spark transformer).
5. **Housekeeping**: #27 (dead code and a wrong pipeline moduledoc), #45 (the
   remaining `||` key-lookup pattern in `field_selector`), #39 (README wrapping
   — half of it, the test-domain warning, is already fixed in
   `config/test.exs`).

## Decided against

- **ADRs, or an `adr/` directory.** [decisions.md](decisions.md) carries the
  choices that still shape the library, one dated entry each. A per-decision
  file set is a journal, and git is already the journal. There has never been
  an `adr/` directory here to migrate.
- **Depending on `ash_typescript`, or making it depend on this library.** The
  extraction was a copy for a reason — see [decisions.md](decisions.md).
- **Adding `jason` as a direct dependency.** `ash` depends on it
  non-optionally, so it is always available, and `mix.exs` declares
  `elixir: "~> 1.15"`, which rules out the stdlib `JSON` module added in 1.18.
- **Shipping this library's own `config/`.** `mix.exs` keeps `config` out of
  the published `files` list so a consumer chooses its own Ash settings; see
  the `default_string_length_count` entry in [decisions.md](decisions.md).

## Keeping this page current

When an issue closes, move it out of "Next" and into "Shipped" with its issue
number and commit SHA, in the same pull request that closes it. When an issue
is closed without shipping, move it to "Decided against" with the reason.
