<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# Roadmap

What has shipped, what is open, and what was declined. Drawn on 2026-09-09 from
`git log --oneline` and `gh issue list --state all`, not from intentions, so a
reader can trust the "shipped" column without checking the log. Issue #36 asked
for this page because the board carries 19 open items with no statement of
which come first. Numbers in parentheses are GitHub issues on
`udin-io/ash_introspection`.

## Shipped

### Unreleased

- **Remove dead code and fix the pipeline moduledoc** (#27). Deleted five
  public functions with zero callers, confirmed by grepping this repo and
  `ash_kotlin_multiplatform`: the TypeScript-named leftovers
  `has_typescript_field_names?/1`, `get_typescript_field_names_map/1` and
  `is_custom_typescript_type?/1`; `classify_ash_type/3` and
  `get_union_types/1`, which upstream had already dropped in `b6ddffd`; and
  the `normalize_value_for_json/1` alias in `ResultProcessor`.
  `get_union_types_from_constraints/2` stays — it backs `TypeDiscovery`,
  `ValidationErrorTypes` and three `ash_kotlin_multiplatform` call sites.
  `get_action_return_type_info/1` in `Rpc.Pipeline` collapsed into its one
  caller, `get_field_mapping_module/3`, which only ever used two of its six
  classification tags. `Rpc.Pipeline`'s moduledoc no longer claims a
  `parse_request/3` this repo does not implement, and no longer lists
  `discover_action` in its example config, which nothing here reads.
- **Format every record of a multi-record read** (#57).
  `format_output_with_request/3` formatted nothing when the result was a plain
  list, so an unpaginated read handed the client internal atom keys.
  `ValueFormatter.format/5` unwraps a collection only when the *type* says
  `{:array, _}`, and `format_action_output/5` passed the bare resource module,
  which carries no cardinality. The paginated read was the same fault one level
  down and had only ever been read off the code: measured on `main` at
  `51a9c27`, an `%Ash.Page.Offset{}` reaches stage 4 as a map, so the envelope
  camelized to `hasMore` correctly while every record inside `:results` kept
  its atom keys, because `:results` is not a field on the resource and
  `ResourceFields.get_field_type_info/2` answers `{nil, []}`. Both shapes now
  format; the page's `:results` are formatted first and the envelope after, so
  nothing is formatted twice. Single-record `get?` reads were always correct,
  which is why 348 tests stayed green — every RPC fixture read one record.
  `test/support/list_output_resources.ex` adds the three read shapes.
  Blocked `ash_kotlin_multiplatform#48`.
- **Stop nilling the values of a generic action that returns an unconstrained
  `{:array, :map}`** (#64). The sibling of #62 one type shape over.
  `unconstrained_map_action?/1` named `Ash.Type.Map` only, so an action
  returning `{:array, :map}` — which Ash normalises to
  `{:array, Ash.Type.Map}` with
  `[items: [preserve_nil_values?: false]]` — fell through to the typed
  path, which has no field definitions to select against and writes `nil` for
  every requested name the caller's maps do not use. Measured on `main` at
  `51a9c27` with a template of `[:id, :name]`,
  `[%{"_id" => "a-1", "name" => "KSR"}]` reached the client as
  `[%{id: nil, name: "KSR"}]`. An array's meaningful constraints live under
  `:items`, so the guard unwraps the tuple and asks
  `Introspection.has_field_constraints?/1` about the inner keyword list —
  reading the key rather than comparing the whole list against a literal, as
  #62 established. Blocked `ash_kotlin_multiplatform#48`.
- **Stop nilling the payload of a generic action that returns an unconstrained
  `:map`** (#62). `unconstrained_map_action?/1` skips field selection when
  there are no field definitions to select against, and it asked for
  `action.constraints == []`. Ash normalises a generic action's constraints
  through `Ash.Type.init/2`, which fills in the return type's declared
  defaults, and `Ash.Type.Map` declares `preserve_nil_values?` with
  `default: false`, so the list always read `[preserve_nil_values?: false]` and
  the skip never fired. Every such response took the typed path, which looked
  up each requested field name in a map that does not use those names and wrote
  `nil` per miss: `%{"_id" => "audit-1", "field_name" => "title"}` reached the
  client as `%{id: nil, name: nil, email: nil}`. Not a regression from the
  `ash` bump in #46 — 3.11.3 normalises the same action to the same
  constraints, measured 2026-09-10 against both versions — so the feature
  never worked. The condition now asks whether `:fields` is present and
  non-empty, through the `Introspection.has_field_constraints?/1` the same file
  already used for the same question. Blocked `ash_kotlin_multiplatform#48`.
  See [`CLAUDE.md`](../CLAUDE.md).
- **Shape an action's loadable surface with `allowed_loads` / `denied_loads`**
  (#19). The core could not restrict what a client loads, so no generator
  built on it could either, and `ash_kotlin_multiplatform` shipped without the
  feature. `AshIntrospection.Rpc.LoadRestrictions` now carries the algebra and
  `FieldSelector` calls `check!/2` at all six points where it appends to the
  Ash load statement, so a nested path is checked at every level rather than
  re-derived from a finished load statement. Restrictions arrive on the config
  map under an optional `:load_restrictions` key, not from
  `Ash.Info.Manifest`, which this repo has not adopted (#23) — see
  [decisions.md](decisions.md). Omitting the key changes nothing for existing
  callers. Ports `ash_typescript` `3aaae6b`, and keeps its framing from
  `24266dc`: this shapes an API surface, it is not authorization.
- **Format action metadata once, and by its declared type** (#20). A metadata
  name is not an attribute, so stage 4 looked it up on the resource, found
  nothing, and handed the value back untouched: the nested keys of a typed-map
  metadata value reached the client in snake_case inside a camelCase response.
  The mutation path had the opposite fault — it camelized the whole metadata
  map recursively, which renamed the keys inside an unconstrained `:map`, an
  explicit opt-out of typing whose keys belong to the caller. Values are now
  formatted at extraction through the same `ValueFormatter` dispatch attributes
  use, which is why `add_read_metadata/5` and `add_mutation_metadata/5` thread
  `request.action`, and the response envelope formats only the top-level
  metadata names. Ports `ash_typescript` `8a05642`, `9e5d05a` and `919e817`.
  The allowlist half of upstream's metadata fix belongs to a parse stage this
  library does not have; see [decisions.md](decisions.md) and risk T4 in
  [risks.md](risks.md).
- **Stop the suite flaking on a torn-down ETS table** (#55).
  `AshIntrospection.Test.Account` now declares `private? true`, so each test
  process gets its own unnamed ETS table instead of sharing one named table for
  the whole VM. The five `Ash.DataLayer.Ets.stop/1` calls in `on_exit` are gone
  with it: `stop/1` kills the table's owning GenServer asynchronously, and the
  next test could wrap the table before the VM reaped it. Measured on the
  branch: `mix test` failed 5 times in 200 runs before the change and 0 times
  in 200 runs after; `pipeline_filter_injection_test.exs` alone went from 11
  failures in 200 runs to 0. See [decisions.md](decisions.md).
- **Guard every consumer-module callback check with `Code.ensure_loaded?/1`**
  (#49). `function_exported?/3` answers `false` for a module the VM has not
  loaded, and Elixir loads lazily, so a domain, resource or type nothing had
  touched silently lost its configuration — a cold VM behaved differently
  from a warm one. Ten call sites across `Rpc.Errors`, `Rpc.ResultProcessor`,
  `Rpc.FieldProcessing.Atomizer`, `Rpc.FieldProcessing.FieldSelector`,
  `Rpc.Pipeline`, `TypeSystem.Introspection` and `Codegen.TypeDiscovery` are
  now guarded. Nine landed in #52; the tenth, in `Rpc.Pipeline`, came with #44,
  which owned that file at the time. That tenth site has no test: both of its
  outcomes converge on `{nil, []}` downstream, so nothing observable changes.
  See [`CLAUDE.md`](../CLAUDE.md).
- **Reject `identity` on read actions, and reject null identity values** (#44,
  [PR #53](https://github.com/udin-io/ash_introspection/pull/53)). `identity`
  selects the record an update or destroy acts on; a read selects one with
  `get_by`, the same split upstream `ash_typescript` draws. A read carrying
  `identity` used to build no filter at all. Breaking for the consumer's
  generated Swift clients — see [decisions.md](decisions.md).
- **Fix type discovery: NewType unwrapping, action arguments, entrypoint
  scoping** (#21). Traversal read the raw constraints of a NewType, so a union
  behind one contributed no members. An embedded resource named directly as an
  action argument was excluded on purpose. Calculation arguments, action
  arguments, a generic action's `:returns` and a read action's metadata were
  never walked at all. Discovery now also takes an optional
  `get_rpc_action_entrypoints` config callback, so a resource exposing only a
  generic action stops pulling every embedded type off its attributes into the
  generated output. Ports `ash_typescript` `8a4051f` and `d981ba6`, and the
  intent of `437901f`; the finer-grained reachability upstream gets from
  `Ash.Info.Manifest` waits on #23.
- **Fix return-type and validation-error classification** (#22).
  `classify_return_type/2` was handed the wrapper rather than the unwrapped
  type, so a generic action returning a NewType was refused field selection on
  a shape that supports it; and every `Ash.Type.Struct` carrying `:instance_of`
  was reported as a resource, including a plain struct with no data layer.
  `Ash.Type.Duration` is now a primitive. `classify_error_type/2` reads a
  custom type's interop name off the original type rather than the unwrapped
  subtype. Ports `ash_typescript` `88783c0`, `618851b`, `ecb1364` and
  `a74c551`.

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
   fixes do not port cleanly. Blocks #24 and #25 and more, and it is where
   the field-name cache declined in #26 would arrive for free, as upstream's
   `Manifest.Custom.formatted_field_names`. It also
   carries the remainder of #21: entrypoint scoping here branches on the action
   kind, where upstream's `Reachability` walks each declared action's accepted
   attributes and follows its relationships to their destinations. It does not
   walk `load` statements — see T1 in [risks.md](risks.md) for the grep.
2. **Correctness fixes that need no manifest**: #40 (second `rescue` in
   `process_single_error` has no `catch` clause), #35 (tuple nested selection
   keys its template from the raw wire name), #16 (a list of errors in
   `build_error_response/1` for bulk actions), #17 (unwrap Reactor step errors,
   serialize `Ash.Type.Vector`).
3. **#18 — the RPC test floor.** Coverage arrives with each fix by preference,
   but the harness and the fixtures are still a ticket of their own.
4. **Upstream parity features**: #24 (relationship query envelopes), #25
   (calculation load-through and nested first-aggregates). #24 touches the same
   `FieldSelector` clauses #19 just guarded: a relationship loaded through an
   `%Ash.Query{}` envelope is a seventh append site and needs its own
   `check_load_allowed!/3`.
5. **Housekeeping**: #45 (the remaining `||` key-lookup pattern in
   `field_selector`), #39 (README wrapping — half of it, the test-domain
   warning, is already fixed in `config/test.exs`).

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
- **Persisting formatted field names via a Spark transformer** (#26). A
  transformer is listed in a `use Spark.Dsl.Extension` call and this library
  ships no DSL, so upstream's `PersistFormattedFields` has nothing to attach
  to; the resource-to-client mapping lives in the consumer's closure, which a
  cache in the core cannot see into. Measured at `0dd9ac5`,
  `format_field_name/2` is ~2% of RPC pipeline wall clock — 6 calls per
  record, two of them response-envelope literals no resource cache would ever
  reach. The cost is the regex predicates, not the missing cache: see
  [decisions.md](decisions.md) for the numbers and the cheaper fix.

## Keeping this page current

When an issue closes, move it out of "Next" and into "Shipped" with its issue
number and commit SHA, in the same pull request that closes it. When an issue
is closed without shipping, move it to "Decided against" with the reason.
