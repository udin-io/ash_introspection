<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# Roadmap

What has shipped, what is open, and what was declined. Drawn on 2026-09-09 from
`git log --oneline` and `gh issue list --state all`, not from intentions, so a
reader can trust the "shipped" column without checking the log. Issue #36 asked
for this page because the board carried 19 open items with no statement of
which come first. Numbers in parentheses are GitHub issues on
`udin-io/ash_introspection`.

## Shipped

### 0.5.2 — 2026-09-18

- **#66 — a nested selection inside a tuple field came back `null`.** Three
  causes, one family with #35 and #84. `FieldSelector.select_tuple_fields/4`
  emitted a nested entry as `{atom, nested}` with no tuple index, and
  `FieldExtractor.convert_tuple_to_map/2` places only an entry that carries
  one; the entry is now `%{field_name:, index:, nested:}` and
  `ResultProcessor` reads `:nested`. `determine_data_type/3` typed a generic
  action's top-level tuple `{Ash.Type.Tuple, []}`, so a tuple two levels down
  came back raw; it reads `:action_returns` now, through the lookup #84 added
  for unions. And a tuple-typed field selected flat reached the extractor with
  an empty template, so every element came back `null`;
  `FieldExtractor.tuple_template/1` builds the positional template from the
  `fields` constraint. Additive. `Test.MapTile` grew `:get_tile_deep`,
  `:list_tiles`, `:get_tile_map` and `:pick_tile`; the suite is 470 tests +
  8 doctests. One neighbour stays open and is pinned: a nested selection on a
  tuple inside a generic action's top-level map result is ignored. See
  [decisions.md](decisions.md).

### 0.5.1 — 2026-09-17

- **#84 — union results came back `null`.** Two causes, both in the request
  path. `FieldSelector.process_nested_union_member/8` keyed a nested member
  entry by its wire name, so `ResultProcessor` never matched it: a read or a
  generic action selecting member fields returned `null`, and a list of three
  unions came back with one. And `ResultProcessor.determine_data_type/3` typed
  a generic action's top-level union from the owning resource's first union
  attribute; it now reads `:action_returns`, which `Pipeline.process_result/3`
  sets from the action. `get_union_constraints_from_resource/2` is deleted.
  Additive. Found measuring `ash_kotlin_multiplatform` 0.2.0, which it blocked.
  `Test.Shelf` carries the fixtures; the suite is 460 tests + 1 doctest. See
  [decisions.md](decisions.md).

### 0.5.0 — 2026-09-17

- **#23 stage 4b — delete `Codegen.TypeDiscovery`, breaking for 0.5.0.**
  `AshIntrospection.Codegen.TypeDiscovery` is gone, all 1109 lines, and so are
  `find_resources_missing_from_rpc_config/2`,
  `find_non_rpc_referenced_resources/2` and its `_with_paths` variant, and the
  two warning builders. A client generator reads its types from a generated
  `%Ash.Info.Manifest{}` instead: `manifest.types` for embedded resources,
  `manifest.resources` for resources. The consumer moved first —
  `ash_kotlin_multiplatform` PR #86 (`70671e8`) — and grep and
  `mix xref callers` found no callers there. Over this repo's fixtures the
  module and `manifest.types` agreed, 7 embedded resources each and 0
  different. `mix ash_introspection.upgrade` gains a 0.5.0 step: a notice
  naming the removed functions and where each answer now lives. Both test
  files that exercised the module went with it, 28 tests; the suite is 451
  tests + 1 doctest. See [decisions.md](decisions.md).
### 0.4.2 — 2026-09-16

- **#78 — the `ash` floor rises to 3.33.4.** `ash` moved from 3.33.1 to
  3.33.4 (#79, `1d518ff`), the first release fixing EEF-CVE-2026-86338: field
  policies did not filter nil forbidden calculations and aggregates, an
  information-disclosure oracle. `reactor` moved to 1.0.7 and `spark` to 2.7.3
  alongside it. The requirement reads `~> 3.33 and >= 3.33.4`, a security
  floor rather than a pin. No call site changed.
- **#23 stage 4a — codegen reads the manifest, and `Codegen.TypeDiscovery`
  stays.** Every private traversal helper in
  `AshIntrospection.Codegen.TypeDiscovery` now carries the config map, and
  every public function takes one, so its 14 introspection reads answer out of
  a manifest when the config has `:manifest` and live when it does not. With a
  manifest, entrypoints come from `manifest.entrypoints` — neither callback is
  required — and `declared_resource?/2` scopes the traversal, so a type
  nobody exposed stops it. `get_rpc_resources` still wins wherever it is
  supplied, because it answers what the consumer listed rather than what has an
  entrypoint, and `find_resources_missing_from_rpc_config/2` stays live because
  it asks what was *not* declared. The proof is
  `test/ash_introspection/manifest/codegen_differential_test.exs`: 423
  comparisons over 22 fixture resources and 23 entrypoints, each asserting the
  two paths return the same term byte for byte. One divergence found and
  recorded rather than smoothed over — the manifest sorts entrypoints and a
  DSL declares them in its own order, so discovery output is reordered on
  adoption; see [decisions.md](decisions.md). `Test.Dossier` is a new fixture:
  the only one whose attribute names a non-embedded resource, which is what
  three readers needed to stop comparing `[]` with `[]`. Additive and
  reversible (#77, `d254c47`). Stage 4b, in 0.5.0 above, deleted the module
  and this differential test with it.

### 0.4.1 — 2026-09-11

- **#23 stage 2 — one compile-time pass writes what this library reads.**
  `AshIntrospection.Manifest.Decorator.decorate/3` walks a generated
  `%Ash.Info.Manifest{}` once and writes under `custom.<namespace>` what the
  request path used to recompute: the live `%Ash.Resource.Attribute{}`,
  `Calculation`, `Aggregate` and action structs, resolved aggregate types,
  each action's return classification, the bulk-authorization strategy,
  client-facing field and argument names under each built-in formatter with
  their reverse maps, how each `:many` relationship paginates and which read
  action it loads through, and an entrypoint lookup keyed by client-facing
  name. `AshIntrospection.Manifest.Custom` reads it back and is the only
  reader of `custom`. Stage 1's field and action readers stopped ignoring the
  manifest, and `Rpc.Pipeline` no longer asks the data layer about bulk
  authorization per request. Additive and reversible: an undecorated resource
  — or no manifest at all — reads live, which is what every caller in this
  repo still does. `test/ash_introspection/manifest/differential_test.exs` is
  the acceptance criterion, comparing every read against live introspection
  field for field and action for action. Ports `ash_typescript` `5292280`,
  `f28feec`, `fe90d56` and `afdae11`. Three stages remain — see below.
- **#23 — a private relationship the manifest omits answers again.**
  `Ash.Info.Manifest.Generator.generate/1` defaults
  `:include_private_relationships?` to `false`, so a private `belongs_to` is in
  no manifest built with the defaults. `ResourceInfo.relationship/3` read the
  manifest and stopped, returning `nil` where `Ash.Resource.Info` returns the
  relationship — and `ResourceFields.get_field_type_info/3` inherited it,
  because it asks `relationship/3` for the field's type. Shipped in stage 1 and
  missed, because stage 1's differential test walks `public_relationships/1`
  only. `Test.Address.user` is the fixture. `public_relationship/3` keeps its
  stop: the manifest carries every public relationship, so a miss there is the
  answer.
- **#40 — a throw or exit from an `Error` protocol implementation no longer
  takes the request with it** (`99cdbd4`). The `rescue` around
  `ErrorProtocol.to_error/1` in `process_single_error/6` only saw exceptions,
  so an implementation that threw or exited escaped `to_errors/6` — the one
  place in the pipeline that must always produce a response. A
  `catch kind, reason` clause now sits beside the `rescue`, and both route
  through one `protocol_failure/3` that returns the same opaque fallback the
  raising case already returned and logs the implementation, the failure, the
  original error and the stacktrace. The wire shape is unchanged, so the log is
  the only correlation — see [decisions.md](decisions.md).
  `test/ash_introspection/rpc/errors_protocol_failure_test.exs` adds 7 tests,
  5 of which fail without the `catch` clause.
- **#61 — the case predicates walk bytes instead of running regexes.**
  `FieldFormatter.format_field_name/2` spent more time deciding what case a
  name was already in than converting it. `is_camel_case?/1`,
  `is_pascal_case?/1` and `is_snake_case?/1` now match on the binary.
  Re-measured 2026-09-11 at `74afafd` on OTP 27 / Elixir 1.18.4, warmed loops
  through `:timer.tc/1`, before and after back to back on one machine:
  `format_field_name(:user_name, :camel_case)` 453-472 ns → 156-170 ns,
  `("userName", :camel_case)` 585-607 ns → 12 ns, `("success", :camel_case)`
  — a response-envelope literal — 773-783 ns → 130-142 ns, and
  `(:user_name, :snake_case)` 355-363 ns → 24-28 ns. Behaviour is unchanged:
  `field_formatter_case_predicate_equivalence_test.exs` keeps the old regexes
  as an oracle and compares both the string returned and the path taken, over
  420 names.
- **#23 stage 1 — one reader for introspection.** All 64 `Ash.Resource.Info`
  call sites in `lib/` now route through `AshIntrospection.ResourceInfo`, which
  reads an optional `:manifest` key off the config map. Omitting the key is
  live introspection exactly as before, proved by comparing every read against
  `Ash.Resource.Info` itself and by running the same RPC request twice.
  `resource?/1` is split into `runtime_resource?/2` (live fallback, request
  path) and `declared_resource?/2` (manifest is the answer, codegen). Additive:
  no consumer change, and reversible by deleting the key. Four stages remain —
  see below.

### 0.4.0 — 2026-09-10

Five breaking changes, all in how a read action selects its record and which
public helpers still exist. `mix ash_introspection.upgrade 0.3.0 0.4.0`
rewrites nothing and prints what each break needs instead — none of the three
has a call site a codemod can find, and the task's moduledoc records why for
each.

- **Remove dead code and fix the pipeline moduledoc** (#27). Deleted six
  public functions with zero callers, confirmed by grepping this repo and
  `ash_kotlin_multiplatform`: the TypeScript-named leftovers
  `has_typescript_field_names?/1`, `get_typescript_field_names_map/1` and
  `is_custom_typescript_type?/1`; `classify_ash_type/3` and
  `get_union_types/1`, which upstream had already dropped in `b6ddffd`; and
  the `normalize_value_for_json/1` alias in `ResultProcessor`.
  `get_union_types_from_constraints/2` stays — it backed `TypeDiscovery`,
  `ValidationErrorTypes` and three `ash_kotlin_multiplatform` call sites.
  `TypeDiscovery` is gone since stage 4b; two consumer call sites remain at
  its `70671e8`.
  `get_action_return_type_info/1` in `Rpc.Pipeline` collapsed into its one
  caller, `get_field_mapping_module/3`, which only ever used two of its six
  classification tags. `Rpc.Pipeline`'s moduledoc no longer claims a
  `parse_request/3` this repo does not implement, and no longer lists
  `discover_action` in its example config, which nothing here reads.
- **Key a nested tuple selection from the resolved atom** (#35, `24e7773`).
  The `{:nested, ...}` branch of `FieldSelector.select_tuple_fields/4` built
  its extraction template from the raw wire name while every sibling branch
  used the resolved atom. `ResultProcessor` matches a nested entry as
  `{atom, nested}`, so the string key fell through its catch-all and the field
  vanished from the response. Measured on `main` at `b99e5a3` against a tuple
  of `{label :: string, corner :: map(x, y)}`: `["label", "corner"]` returned
  both fields, `[%{"corner" => ["x", "y"]}]` returned `%{}`, and the
  multi-entry spelling of the same request returned `%{"corner" => nil}` —
  three answers to one request. `test/support/tuple_selection_resources.ex` is
  the first tuple fixture with a nested-selectable field; `Test.Post.get_bounds`
  carries two floats, so the branch had no coverage at all. The value still
  did not survive, because a nested entry carried no tuple index: that was
  #66, shipped under 0.5.2 above.
- **Read the calculation envelope keys by presence, not truthiness** (#45,
  `14d806e`). `get_args_and_fields/1` kept the
  `Map.get(m, :args) || Map.get(m, "args")` shape that #15 removed from
  `result_processor`. Latent for data, as the issue said — `:args` is a map
  and `:fields` is a list, and neither `%{}` nor `[]` is falsy — but not
  inert: `||` returns its right operand when both sides are falsy, so a
  present-and-`false` value survived under the string key and was erased under
  the atom key. Measured on `main` at `b99e5a3`, `%{"slug" => %{fields:
  false}}` loaded the calculation and dropped the selection while
  `%{"slug" => %{"fields" => false}}` rejected it. `Map.fetch/2` before the
  string key, in the style of `plain_map_field/2`. `nil` keeps its meaning: a
  JSON `null` under `:args` is "no arguments", so the `not is_nil/1` guard
  stays and both null cases answer as they did before.
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
  now guarded. Stage 4b of #23 deleted `Codegen.TypeDiscovery`, so nine
  remain. Nine landed in #52; the tenth, in `Rpc.Pipeline`, came with #44,
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
- **Handle a list of errors, unwrap Reactor step errors, serialize
  `Ash.Type.Vector`** (#16, #17, `66cdc72`). `Ash.bulk_create/update/destroy`
  return `%Ash.BulkResult{errors: [...]}`, and a list matched neither
  `is_exception` nor `is_map` in `build_error_response/1`, so every per-record
  validation error collapsed into one "An unexpected error occurred".
  `%Reactor.Error.Invalid.RunStepError{}` is itself an exception, so it matched
  the generic Ash clause and the client got a notice naming a step it has never
  heard of. `%Ash.Vector{}` keeps its floats in a packed binary that `Jason`
  refuses to encode. Merged three hours after the 0.3.0 changelog section was
  cut, so it ships here.
- **Closed without a code change**: #26, which is in "Decided against" below
  with its measurement, and #39, whose two halves had both already landed —
  the README reflow in #51, the test-domain warning in `config/test.exs` in
  #42. #61 was filed out of #26 and shipped in 0.4.1 above.

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

- **#23 stage 5a, PR 1 of 4 — the request path reads the manifest it is
  given.** The stage-3 processor config and `value_formatter_config/2` carry
  `:manifest` and `:manifest_namespace` instead of dropping them, the three
  request entry points prepare the manifest once per stage, and seven reads
  that passed no config now pass it. Additive, for 0.5.3; the suite is 477
  tests + 8 doctests. PR 2 (decorate every relationship) and PR 6 (require the
  manifest, breaking, 0.6.0) follow here; PR 4 puts a manifest on the request
  path in `ash_kotlin_multiplatform`. Stage 5b, manifest-shaped return values,
  moved to [#83](https://github.com/udin-io/ash_introspection/issues/83).

## Next

Ordered by what unblocks the most. #23 is first because it gates roughly a
dozen other items.

1. **#23 — adopt `Ash.Info.Manifest`, stage 5a.** Stages 1, 2, 4a and 4b
   shipped here; stage 3 shipped in the consumer. The manifest module itself
   cannot live here: building one needs a Spark DSL to declare entrypoints, and
   this library ships none — the recorded reason #26 was declined. So it goes
   in `ash_kotlin_multiplatform`, next to the DSL that already names the RPC
   actions. The stages, in the order that keeps the escape hatch open longest:

   | Stage | Repo | Delivers | Release | State |
   |---|---|---|---|---|
   | 1 | this | `AshIntrospection.ResourceInfo` and the optional `:manifest` key | 0.4.x, additive | shipped |
   | 2 | this | `Manifest.Decorator.decorate/3` and `Manifest.Custom`: field and argument name maps, `formatted_field_names`, `return_classification`, per-relationship pagination | 0.4.x, additive | shipped |
   | 3 | consumer | `use AshKotlinMultiplatform.Manifest`, its two transformers, the `8c07331` compile-time edges, an installer | consumer minor | shipped |
   | 4a | this | codegen reads the manifest; `Codegen.TypeDiscovery` stays, proved byte-identical | 0.4.x, additive | shipped |
   | 4b | this | delete `Codegen.TypeDiscovery` (1109 lines); codegen reads the manifest only | 0.5.0, breaking | shipped |
   | 5a PR 1 | this | every request-path read gets the manifest: both config rebuilds carry `:manifest` and `:manifest_namespace`, the entry points prepare it once | 0.5.3, additive | in review |
   | 5a PR 2 | this | decorate every relationship, private included, so `relationship/3` needs no live fallback | 0.5.3, additive | next |
   | 5a PR 4 | consumer | a manifest on the request path; `Runner` resolves actions through `rpc_action_lookup` | consumer minor | next |
   | 5a PR 6 | this | make `:manifest` required at the four entry points; a carried but undecorated resource raises; drop the manifest-miss live reads | 0.6.0, breaking | next |
   | 5b | this | manifest-shaped return values in place of the captured Ash structs, deferred from stage 2 ([#83](https://github.com/udin-io/ash_introspection/issues/83)) | 0.6.x | next |

   **Stage 4 is split on purpose.** Reading a manifest and deleting the live
   walk are two changes with different risk: the first is additive and
   testable against the thing it replaces, the second is breaking and has
   nothing left to compare against. 4a landed the reading path with a
   differential test; 4b deleted the module once consumer PR #86 generated
   from the manifest.

   Stage 2 is where the field-name cache declined in #26 arrived for free, as
   `Manifest.Custom.formatted_field_names`. Stage 4b closed the remainder of
   #21: the deleted module scoped entrypoints by action kind, and codegen now
   takes its types from upstream's `Reachability`, which walks each declared
   action's accepted attributes and follows its relationships to their
   destinations. It does not walk `load` statements — see T1 in
   [risks.md](risks.md) for the grep. The consumer deleted its own copy of the
   traversal in its PR #83.

   Two traps the design surfaced and stage 3 must not inherit: `8c07331` is
   not optional (without its injected `domain.module_info(:md5)` and
   `Application.compile_env/3` edges the persisted manifest goes stale under
   incremental compiles with no error), and `SpecCache` must not be ported —
   upstream added it in `199f9cd` and deleted it in `b7104a8` because Spark's
   persisted DSL state is already free at runtime.
2. **A tuple inside a generic action's top-level map result ignores a nested
   selection** and returns every element (found by #66's neighbour checks, no
   issue yet). The map is typed `{nil, []}` because Ash hands a `run` result
   back uncast and the typed map path reads atom keys only (#62); the fix is a
   typed path that reads string keys too. #40 shipped in 0.4.1 and #66 under
   Unreleased, both above.
3. **#18 — the RPC test floor.** Coverage arrives with each fix by preference,
   but the harness and the fixtures are still a ticket of their own.
4. **Upstream parity features**: #24 (relationship query envelopes), #25
   (calculation load-through and nested first-aggregates). #24 touches the same
   `FieldSelector` clauses #19 just guarded: a relationship loaded through an
   `%Ash.Query{}` envelope is a seventh append site and needs its own
   `check_load_allowed!/3`.

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
