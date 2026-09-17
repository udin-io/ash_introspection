<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.1] - 2026-09-17

Additive. A union value no longer comes back `null`, or drops from a list,
when the caller selects member fields
([#84](https://github.com/udin-io/ash_introspection/issues/84)) — for a read
selecting a union member with nested fields and for a generic action
returning a union. Two visible changes: `FieldSelector.process/4` puts atom
member keys in the extraction template where it put strings, and
`ResultProcessor.process/4` reads a new `:action_returns` config key that
`Pipeline.process_result/3` now sets for every generic action, so a direct
caller that does not pass it gets untyped union members. No breaking change,
so no upgrade task is needed.

### Fixed

- A union value no longer comes back `null` when the caller selects member
  fields ([#84](https://github.com/udin-io/ash_introspection/issues/84)).
  Two causes:
  - `FieldSelector` keyed a nested union member entry by its wire name, and
    `ResultProcessor` matches members by atom. A read selecting a union
    attribute with nested member fields returned `null`, and a list of unions
    dropped the item.
  - `ResultProcessor` typed a union a generic action returns from the owning
    resource's first union attribute. It now reads the action's own return
    constraints, through `{:array, _}` and a NewType, so a selection is
    honoured and undeclared keys stay out. An empty template returns the
    active member's declared fields.

  Two visible changes:
  - `FieldSelector.process/4` puts atom member keys in the extraction template
    where it put strings.
  - `ResultProcessor.process/4` reads a new `:action_returns` config key,
    `{returns, constraints}`. `Pipeline.process_result/3` sets it for every
    generic action. A direct caller that does not pass it gets untyped union
    members.

## [0.5.0] - 2026-09-17

**Breaking.** `AshIntrospection.Codegen.TypeDiscovery` is deleted (stage 4b of
[#23](https://github.com/udin-io/ash_introspection/issues/23)), and codegen
reads the manifest only. Run the upgrade task before anything else:

```
mix igniter.upgrade ash_introspection
```

It rewrites nothing for 0.5.0 and prints a notice naming each removed
function and where its answer now lives. To run it on its own:
`mix ash_introspection.upgrade 0.4.2 0.5.0`. A consumer pinned to `~> 0.4`
does not take this release; bumping to `~> 0.5` is a deliberate step in the
consumer's own pull request.

### Removed

- **Breaking.** `AshIntrospection.Codegen.TypeDiscovery`, all 1109 lines
  ([#23](https://github.com/udin-io/ash_introspection/issues/23)). A client
  generator reads its types from a generated `%Ash.Info.Manifest{}` instead:
  embedded resources are the `manifest.types` entries whose `kind` is
  `:embedded_resource`, and resources are `manifest.resources`.
  `ash_kotlin_multiplatform` moved first, in its PR #86; at its `70671e8`
  grep and `mix xref callers` find no caller. Over this repo's test fixtures
  the module and `manifest.types` found the same 7 embedded resources.
- **Breaking.** `find_resources_missing_from_rpc_config/2`,
  `find_non_rpc_referenced_resources/2`,
  `find_non_rpc_referenced_resources_with_paths/2`,
  `build_missing_config_warning/3` and `build_non_rpc_references_warning/2`,
  with the module and with no replacement. They reported resources a consumer
  had not declared, and a manifest carries only what was declared.
  `ResourceInfo.declared_resource?/2` and
  `TypeSystem.Introspection.get_union_types_from_constraints/2` stay.

### Added

- A 0.5.0 step in the `ash_introspection.upgrade` task: a notice for the removal
  above. It touches no file, because the replacement needs a generated
  manifest that a call-site rewrite cannot build.

## [0.4.2] - 2026-09-16

Additive, and a security release. The `ash` floor rises to 3.33.4, the first
release fixing EEF-CVE-2026-86338, and codegen reads a manifest when the config
carries one (stage 4a of
[#23](https://github.com/udin-io/ash_introspection/issues/23)). No breaking
change, so no upgrade task is needed.

### Fixed

- `ash` bumped from 3.33.1 to 3.33.4
  ([#78](https://github.com/udin-io/ash_introspection/issues/78)), clearing
  advisory EEF-CVE-2026-86338 (field policies not filtering nil forbidden
  calculations and aggregates, an information-disclosure oracle; affects
  `>= 2.11.0-rc.0, < 3.33.4`). `mix igniter.upgrade ash@3.33.4` moved
  `reactor` 1.0.6 to 1.0.7 and `spark` 2.7.2 to 2.7.3 alongside it. The
  dependency reads `{:ash, "~> 3.33 and >= 3.33.4"}` (was `"~> 3.33"`) — a
  security floor, not a pin, so a consumer stays free to take 3.33.5 and
  later without this library forcing an exact version on it. No call site
  changed; full suite green.

### Changed

- `AshIntrospection.Codegen.TypeDiscovery` reads a manifest. Every private
  traversal helper now carries the config map and every public function takes
  one, so its 14 introspection reads answer out of `config[:manifest]` when the
  config has one and out of live `Ash.Resource.Info` when it does not. With a
  manifest, entrypoints come from `manifest.entrypoints` — neither
  `get_rpc_action_entrypoints` nor `get_rpc_resources` is required — and
  `ResourceInfo.declared_resource?/2` scopes the traversal, so a type nobody
  exposed stops it. `get_rpc_resources` still wins wherever it is supplied, and
  `find_resources_missing_from_rpc_config/2` still scans domains live, because
  it asks what was *not* declared. Additive: a config with no `:manifest` key
  behaves exactly as before. Stage 4a of
  [#23](https://github.com/udin-io/ash_introspection/issues/23); stage 4b
  deletes the module and is breaking.

  Seven public functions gained an optional trailing `config` argument:
  `scan_rpc_resource/3`, `find_referenced_embedded_resources/2`,
  `find_referenced_non_embedded_resources/2`, `find_referenced_resources/2`,
  `find_struct_argument_resources/2`, `traverse_type/3` and
  `traverse_fields/2`. Existing calls compile unchanged.

  One behaviour difference is documented rather than corrected: a manifest
  sorts its entrypoints and a DSL declares them in its own order, so codegen
  output is reordered once a consumer passes `:manifest`. See
  `docs/decisions.md`.

### Added

- `test/ash_introspection/manifest/codegen_differential_test.exs`. Runs every
  public function of `Codegen.TypeDiscovery` against live introspection and
  against a decorated manifest — 423 comparisons over 22 fixture resources and
  23 entrypoints — and asserts each pair of results is the same term byte for
  byte.

## [0.4.1] - 2026-09-11

Additive. Stages 1 and 2 of
[#23](https://github.com/udin-io/ash_introspection/issues/23) land the manifest
seam and the decoration that fills it, a protocol implementation that throws or
exits can no longer take a request down, and the field-name case predicates stop
running regexes. No breaking change, so no upgrade task is needed.

Stage 2 is inert until a consumer builds a manifest.
`AshIntrospection.Manifest.Decorator.decorate/3` has no caller in `lib/` — the
manifest module needs a Spark DSL to declare entrypoints and this library ships
none. `ash_kotlin_multiplatform` declares it in stage 3.

### Added

- `AshIntrospection.ResourceInfo`, the one module in `lib/` that calls
  `Ash.Resource.Info` — all 64 call sites route through it. It reads an
  optional `:manifest` key off the config map the pipeline and codegen already
  thread, the same shape `:load_restrictions` uses. Omitting the key reads live
  introspection exactly as before, so nothing changes for a caller that does
  not pass one. Stage 1 of five for
  [#23](https://github.com/udin-io/ash_introspection/issues/23); see
  `docs/roadmap.md` for the rest.

  `Ash.Resource.Info.resource?/1` and `Ash.Info.Manifest.has_resource?/2` are
  not the same question, so the reader exposes both.
  `ResourceInfo.runtime_resource?/2` falls back to live introspection for a
  module the manifest does not carry — the request path needs that, because a
  struct Ash handed back must still serialize as a resource.
  `ResourceInfo.declared_resource?/2` treats absence as the answer, which is
  what codegen wants.

- An optional trailing `config` argument on six public functions, defaulting to
  live introspection so no existing call breaks:
  `TypeSystem.Introspection.is_embedded_resource?/2` and
  `is_resource_instance_of?/2`, `TypeSystem.ResourceFields`' three lookups,
  `Codegen.ActionIntrospection.action_input_type/3`, `get_required_inputs/3`,
  `get_optional_inputs/3`, `action_returns_field_selectable_type?/2`,
  `action_supports_field_selection?/2`, and
  `Codegen.ValidationErrorTypes.classify_action_input_errors/3` and
  `classify_resource_attribute_errors/2`.

- `AshIntrospection.Manifest.Decorator` and `AshIntrospection.Manifest.Custom`,
  stage 2 of five for
  [#23](https://github.com/udin-io/ash_introspection/issues/23).
  `Decorator.decorate/3` walks a generated `%Ash.Info.Manifest{}` once at
  compile time and writes what this library reads under `custom.<namespace>`;
  `Custom` is the only module that reads it back. Between them they precompute
  the field and argument name maps and their reverses, `formatted_field_names`,
  each action's return classification, each relationship's pagination and read
  action, and the bulk-authorization strategy.

  Additive and reversible: a config map with no `:manifest` key reads live
  introspection exactly as before, and `decorated?/2` distinguishes a resource
  with no decoration from one with no fields. The namespace is a parameter
  defaulting to `:ash_introspection`, because whether one decoration serves
  every generator or each generator decorates under its own key is still open
  on #23.

  A differential test compares roughly 2,560 reads per run — every reader, in
  both atom and string spellings, against a decorated manifest and against
  `Ash.Resource.Info` — and requires the two to agree.

### Changed

- `FieldFormatter.format_field_name/2` matches on the binary instead of running
  regexes to decide what case a name is already in
  ([#61](https://github.com/udin-io/ash_introspection/issues/61)).
  `is_camel_case?/1`, `is_pascal_case?/1` and `is_snake_case?/1` walk bytes.
  Measured at `74afafd` on OTP 27 / Elixir 1.18.4, warmed loops through
  `:timer.tc/1`: `(:user_name, :camel_case)` 453-472 ns to 156-170 ns,
  `("userName", :camel_case)` 585-607 ns to 12 ns, `("success", :camel_case)`
  773-783 ns to 130-142 ns, `(:user_name, :snake_case)` 355-363 ns to 24-28 ns.
  Behaviour is unchanged: the old regexes stay in the suite as an oracle over
  420 names, comparing both the string returned and the path taken.

### Fixed

- A `AshIntrospection.Rpc.Error` implementation that throws or exits no longer
  escapes error transformation and takes the request with it
  ([#40](https://github.com/udin-io/ash_introspection/issues/40)). The `rescue`
  around `ErrorProtocol.to_error/1` saw exceptions only. Raise, throw and exit
  now route through one `protocol_failure/3` returning the same opaque fallback
  the raising case already returned. The response shape is unchanged, so the
  log is the only correlation: it names the implementation, the failure, the
  original error and the stacktrace.

- `ResourceInfo.relationship/3` answers for a private relationship again.
  `Ash.Info.Manifest.Generator.generate/1` defaults
  `:include_private_relationships?` to `false`, so a private `belongs_to` is in
  no manifest built with the defaults; the reader consulted the manifest and
  stopped, returning `nil` where `Ash.Resource.Info.relationship/2` answers.
  It now falls back to live introspection on a miss.
  `public_relationship/3` keeps its stop — every public relationship is
  carried, so a miss there is the answer. Shipped in stage 1 and caught by
  stage 2's differential test, which walks every relationship rather than only
  the public ones.

## [0.4.0] - 2026-09-10

Five breaking changes: a read action may no longer carry `identity`, a `null`
identity value is refused, and six public functions with no callers are gone.
Run the upgrade task before anything else:

```
mix igniter.upgrade ash_introspection
```

For 0.4.0 it rewrites nothing and prints what each break needs instead — no
break in this release has a call site a codemod can find, and
`mix ash_introspection.upgrade`'s moduledoc records why for each one. To run it
on its own: `mix ash_introspection.upgrade 0.3.0 0.4.0`.

The `identity` change is the one that reaches a client. Generated Swift clients
from `ash_kotlin_multiplatform` send `identity` on every `get?` read
(`swift/codegen.ex`, `generate_get_function/3`); regenerate them against an
action that uses `get_by`.

[#26](https://github.com/udin-io/ash_introspection/issues/26) also closed in
this release, without a code change: a compile-time field-name cache cannot be
built here, and would buy little if it could. See `docs/decisions.md`.

### Added

- `AshIntrospection.Rpc.LoadRestrictions`, and an optional `:load_restrictions`
  key on the field-selection config map
  ([#19](https://github.com/udin-io/ash_introspection/issues/19)). It takes
  `{:allow, spec}` or `{:deny, spec}`, where `spec` nests internal field names
  (`[comments: [:score]]`), and shapes which relationships, calculations and
  aggregates an action will load.
  `AshIntrospection.Rpc.FieldProcessing.FieldSelector` checks it at all six
  points where it appends to the Ash load statement, so a nested path is
  checked at every level. Omitting the key permits every load, so no consumer
  has to act. A refused load answers `load_not_allowed` or `load_denied`,
  naming the dotted path. **This is an API surface control, not
  authorization** — Ash policies apply to every load that gets through.

### Changed

- **Breaking.** A read action carrying `identity` is rejected with
  `identity_not_supported` instead of having the parameter dropped
  ([#44](https://github.com/udin-io/ash_introspection/issues/44)). `identity`
  selects a record for update and destroy; reads select one with `get_by`, the
  same split upstream `ash_typescript` draws. A read used to build no filter at
  all, so the caller named one record and got the whole table, or a
  `MultipleResults` from `Ash.read_one/1`. Generated Swift clients from
  `ash_kotlin_multiplatform` send `identity` on `get?` reads and must move
  those calls to `get_by`.
- **Breaking.** A `null` identity value is rejected with `invalid_identity`
  ([#44](https://github.com/udin-io/ash_introspection/issues/44)). It used to
  compile to `key == nil`, which Ash evaluates as unknown, so the lookup
  matched nothing and surfaced as `NotFound`.
- `AshIntrospection.Codegen.TypeDiscovery` accepts an optional
  `get_rpc_action_entrypoints` config callback
  ([#21](https://github.com/udin-io/ash_introspection/issues/21)). It returns
  `%{resource: module, action: atom}` maps or `{module, atom}` tuples, and
  scopes discovery to those actions: a read, create, update or destroy
  entrypoint keeps the resource's own fields in scope, a generic action reaches
  only its own arguments, `:returns` and metadata. Omitting the key keeps the
  previous whole-resource scope, so no consumer has to act.
- `action_returns_field_selectable_type?/1` distinguishes a resource from a
  plain typed struct
  ([#22](https://github.com/udin-io/ash_introspection/issues/22)).
  `Ash.Type.Struct` accepts any struct module as `:instance_of`, and every one
  used to come back as `{:ok, :resource, module}`, sending field selection off
  to build a load statement against a module with no data layer. A non-resource
  `instance_of` now returns `{:ok, :typed_struct, {module, fields}}`, or
  `{:error, :not_field_selectable_type}` when it declares no fields. Both were
  already documented returns of this function; a consumer matching only
  `{:ok, :resource, _}` for such an action sees the change.

### Fixed

- A generic action returning an unconstrained `:map` hands its payload to the
  client verbatim, values included
  ([#62](https://github.com/udin-io/ash_introspection/issues/62)). The check
  that skips field selection for such an action compared the whole constraints
  keyword list against `[]`. Ash normalises a generic action's constraints
  through `Ash.Type.init/2`, which fills in the return type's declared
  defaults, and `Ash.Type.Map` declares `preserve_nil_values?` with
  `default: false`, so the list always read `[preserve_nil_values?: false]` and
  the skip never fired. Every such response went through the typed path, which
  has no field definitions to work from: it looked up each requested name in a
  map that does not use those names and wrote `nil` for every miss, so
  `%{"_id" => "audit-1", "field_name" => "title"}` reached the client as
  `%{id: nil, name: nil, email: nil}`. This never worked; it is not a
  regression from the `ash` 3.11.3 → 3.33.1 bump in
  [#46](https://github.com/udin-io/ash_introspection/issues/46), because
  3.11.3 normalises the same action to the same
  `[preserve_nil_values?: false]`. The condition now asks whether `:fields` is
  present and non-empty, so an incidental constraint cannot kill it again.
- A generic action returning an unconstrained `{:array, :map}` keeps its values
  too ([#64](https://github.com/udin-io/ash_introspection/issues/64)). The
  sibling of #62 one type shape over: the guard named `Ash.Type.Map` only, and
  Ash normalises `{:array, :map}` to `{:array, Ash.Type.Map}` with the
  element's constraints under `:items`, so an array fell through to the typed
  path. Measured on `main` at `51a9c27` with a template of `[:id, :name]`,
  `[%{"_id" => "a-1", "name" => "KSR"}]` reached the client as
  `[%{id: nil, name: "KSR"}]`. The guard now unwraps the tuple and reads
  `constraints[:items]`.
- Every record of a multi-record read is formatted
  ([#57](https://github.com/udin-io/ash_introspection/issues/57)).
  `format_output_with_request/3` formatted nothing when the result was a plain
  list, so an unpaginated read handed the client internal atom keys.
  `ValueFormatter.format/5` unwraps a collection only when the *type* says
  `{:array, _}`, and a bare resource module carries no cardinality. A paginated
  read failed a second way: an `%Ash.Page.Offset{}` is a map, so the envelope
  camelized to `hasMore`, but `:results` is not a field on the resource and
  every record inside it kept its atom keys. Both shapes now format, the page's
  `:results` first and the envelope after, so nothing is formatted twice.
  Single-record `get?` reads were always correct, which is why 348 tests stayed
  green — every RPC fixture read one record.
- A nested selection inside a tuple field is keyed from the resolved atom
  ([#35](https://github.com/udin-io/ash_introspection/issues/35)). The
  `{:nested, ...}` branch of `FieldSelector.select_tuple_fields/4` built its
  extraction template from the raw wire name while every sibling branch used
  the atom, and `ResultProcessor` matches a nested entry as `{atom, nested}`,
  so the string key fell through a catch-all and the field vanished. Measured
  on `main` at `b99e5a3` against a tuple of
  `{label :: string, corner :: map(x, y)}`, one request had three answers
  depending on how it was spelled. The value itself still does not survive,
  because a nested entry carries no tuple index — that is
  [#66](https://github.com/udin-io/ash_introspection/issues/66), pinned by an
  assertion in the new test.
- A calculation envelope's `args` and `fields` keys are read by presence, not
  truthiness ([#45](https://github.com/udin-io/ash_introspection/issues/45)).
  `get_args_and_fields/1` kept the `Map.get(m, :args) || Map.get(m, "args")`
  shape that #15 removed elsewhere. `||` returns its right operand when both
  sides are falsy, so a present-and-`false` value survived under the string key
  and was erased under the atom key: measured on `main` at `b99e5a3`,
  `%{"slug" => %{fields: false}}` loaded the calculation and dropped the
  selection while `%{"slug" => %{"fields" => false}}` rejected it. `nil` keeps
  its meaning — a JSON `null` under `:args` is still "no arguments".
- Every check against a consumer-supplied module is guarded with
  `Code.ensure_loaded?/1`
  ([#49](https://github.com/udin-io/ash_introspection/issues/49)).
  `function_exported?/3` answers `false` for a module the VM has not loaded,
  and Elixir loads lazily, so a domain, resource or type nothing had touched
  silently lost its configuration and a cold VM behaved differently from a warm
  one. Ten call sites across `Rpc.Errors`, `Rpc.ResultProcessor`,
  `Rpc.FieldProcessing.Atomizer`, `Rpc.FieldProcessing.FieldSelector`,
  `Rpc.Pipeline`, `TypeSystem.Introspection` and `Codegen.TypeDiscovery` are
  now guarded.
- Test suite only: `AshIntrospection.Test.Account` declares `private? true`, so
  each test process gets its own ETS table
  ([#55](https://github.com/udin-io/ash_introspection/issues/55)). The five
  `Ash.DataLayer.Ets.stop/1` calls in `on_exit` are gone with it — `stop/1`
  kills the table's owning process asynchronously, so the next test could wrap
  a table the VM had not yet reaped. `mix test` failed 5 times in 200 runs
  before the change and 0 times in 200 runs after. No library code changed.
- Action metadata is formatted once, by the type its action declared for it
  ([#20](https://github.com/udin-io/ash_introspection/issues/20)). A metadata
  name is not an attribute, so stage 4 looked it up on the resource, found
  nothing and passed the value through: the nested keys of a typed-map
  metadata value reached the client in snake_case inside a camelCase response.
  Values now go through the same `ValueFormatter` dispatch attributes use, at
  extraction, where the declaration is readable.
- Metadata values are no longer formatted a second time by the response
  envelope ([#20](https://github.com/udin-io/ash_introspection/issues/20)).
  Only the top-level metadata names are formatted there. Formatting a value
  twice is not idempotent: a field pinned to the client name `_rev` by its
  type's `interop_field_names/0` came out as `rev`.
- A metadata field declared as an unconstrained `:map` reaches the client with
  its keys intact
  ([#20](https://github.com/udin-io/ash_introspection/issues/20)). An
  unconstrained map is an explicit opt-out of typing, so its keys belong to
  whoever wrote them. The guarantee holds on
  `Rpc.Pipeline.format_output_with_request/3`, which has the types;
  `format_output/2` has no request and still formats every key it reaches.
- A failing bulk action reaches the client as one error per failed field
  ([#16](https://github.com/udin-io/ash_introspection/issues/16)).
  `Ash.bulk_create/update/destroy` return `%Ash.BulkResult{errors: [...]}` and
  the pipeline forwards that list. A list matched neither `is_exception` nor
  `is_map` in `build_error_response/1`, so every per-record validation error
  collapsed into one "An unexpected error occurred".
- A Reactor-backed action reports the error its step produced, not the
  wrapper ([#17](https://github.com/udin-io/ash_introspection/issues/17)).
  `%Reactor.Error.Invalid.RunStepError{}` is itself an exception, so it matched
  the generic Ash clause and the client got a step-execution notice naming a
  step it has never heard of.
- `Ash.Type.Vector` values serialize as a list of numbers
  ([#17](https://github.com/udin-io/ash_introspection/issues/17)).
  `%Ash.Vector{}` keeps its floats in a packed binary that `Jason` refuses to
  encode, so selecting a vector field either crashed the encoder or put
  `%{data: <<...>>, dimensions: n}` on the wire.
- Type discovery unwraps NewTypes before reading constraints
  ([#21](https://github.com/udin-io/ash_introspection/issues/21)). A NewType
  keeps its `:types`, `:fields` and `:instance_of` on itself, so the wrapper's
  raw constraints are empty: a union behind one contributed no members and its
  embedded resources reached no generator.
- Type discovery finds an embedded resource named directly as an action
  argument ([#21](https://github.com/udin-io/ash_introspection/issues/21)).
  Discovery matched only bare `Ash.Type.Struct` and then excluded embedded
  resources on purpose, so a client got no type for an argument it has to
  build.
- Type discovery walks calculation arguments, action arguments, a generic
  action's `:returns` and a read action's metadata
  ([#21](https://github.com/udin-io/ash_introspection/issues/21)). It covered
  attributes, calculations and aggregates only.
- `classify_return_type/2` unwraps NewTypes, so a generic action returning one
  is no longer refused field selection on a shape that supports it
  ([#22](https://github.com/udin-io/ash_introspection/issues/22)).
- `Ash.Type.Duration` classifies as a primitive
  ([#22](https://github.com/udin-io/ash_introspection/issues/22)). It reaches a
  client as one ISO 8601 string and has no fields to select.
- `classify_error_type/2` reads a custom type's `interop_type_name/0` off the
  original type rather than the unwrapped subtype
  ([#22](https://github.com/udin-io/ash_introspection/issues/22)). A NewType
  declaring its own interop name was routed to the container branch instead.

### Removed

- **Breaking.** `AshIntrospection.TypeSystem.Introspection.classify_ash_type/3`
  and `get_union_types/1`
  ([#27](https://github.com/udin-io/ash_introspection/issues/27)). Upstream
  `ash_typescript` dropped both in `b6ddffd`; here their only callers were
  their own unit tests. `get_union_types_from_constraints/2` is unaffected and
  stays — it is live, used by `Codegen.TypeDiscovery`,
  `Codegen.ValidationErrorTypes`, and three sites in
  `ash_kotlin_multiplatform`.
- **Breaking.**
  `AshIntrospection.TypeSystem.Introspection.has_typescript_field_names?/1`,
  `get_typescript_field_names_map/1` and `is_custom_typescript_type?/1`
  ([#27](https://github.com/udin-io/ash_introspection/issues/27)). These
  duplicated the generalized `interop_field_names`/`interop_type_name`
  helpers for one language generator, in a core meant to stay
  language-agnostic. Grep of this repo's `lib/` and `test/`, and of
  `ash_kotlin_multiplatform`'s `lib/`, finds no caller of any of the three.
- **Breaking.**
  `AshIntrospection.Rpc.ResultProcessor.normalize_value_for_json/1`
  ([#27](https://github.com/udin-io/ash_introspection/issues/27)). A
  backwards-compatibility alias for `normalize_primitive/1` with no caller in
  this repo or `ash_kotlin_multiplatform`.
- No codemod ships for the six functions above. Each was confirmed to
  have zero callers, in this repo and in the one known consumer
  (`ash_kotlin_multiplatform`), before deletion — a codemod would have
  nothing to rewrite. If your code calls one of them outside those two
  repos, replace `classify_ash_type/3` and `get_union_types/1` with your own
  logic (or a copy from before this release), replace the TypeScript-named
  helpers with the `interop_*` equivalents already public on the same
  module, and replace `normalize_value_for_json/1` with
  `normalize_primitive/1`.

## [0.3.0] - 2026-09-09

Two breaking changes to the RPC error payload. Run the codemod that ships with
this release before anything else:

```
mix igniter.upgrade ash_introspection
```

It rewrites Elixir code reading `code` off an error to `type`, and prints the
shapes it could not decide — pattern matches such as `%{code: code} = error`,
reads off an expression rather than a variable, and generated TypeScript or
Kotlin clients, which you regenerate instead. To run it on its own:
`mix ash_introspection.upgrade 0.2.0 0.3.0`.

### Security

- Forbidden errors no longer render the policy breakdown to the client
  ([#11](https://github.com/udin-io/ash_introspection/issues/11)).
  `Exception.message/1` on `Ash.Error.Forbidden.Policy` returns the whole
  authorization report — every policy, every check outcome, and the actor
  inspected in full — whenever Ash's app-wide
  `config :ash, :policies, show_policy_breakdowns?: true` is set, so a
  development toggle opened every RPC response. The message is now the static
  `"forbidden"` and the `policy_breakdown` key is gone.

- Unknown errors no longer return the raw exception text
  ([#11](https://github.com/udin-io/ash_introspection/issues/11)).
  `Ash.Error.Unknown.UnknownError` is the bucket every unrecognised exception
  falls into, so its message could be a connection string, a stack trace or a
  third-party library's internals. Clients now get `"Something went wrong"`.

- Client-supplied field names no longer mint atoms
  ([#10](https://github.com/udin-io/ash_introspection/issues/10)). The atom
  table is never garbage collected, so a request carrying unknown field names
  grew it without bound and could take the node down. Field selection now
  resolves names against atoms that already exist and rejects the rest as
  unknown fields.

### Changed

- **Breaking:** every RPC error names its class under `type`
  ([#14](https://github.com/udin-io/ash_introspection/issues/14)). The
  `AshIntrospection.Rpc.Error` protocol already emitted `type`, but the
  fallback paths in `AshIntrospection.Rpc.Errors` emitted `code`, so a client
  reading `error.type` got `nil` for exactly the errors it could not
  anticipate — an exception with no protocol implementation, an
  implementation that raised, and a domain with `show_raised_errors?` set. The
  `code` key is gone. A client reads `type`.

- **Breaking:** an error's `%{name}` placeholders now match the keys in `vars`
  ([#14](https://github.com/udin-io/ash_introspection/issues/14)). An error map
  is a template: `message`, `short_message` and the strings under `details`
  carry placeholders, `vars` carries the values, and the client interpolates so
  it can localize. Stage 4 camelized every nested key, `vars` included, and
  never touched the message, so `%{action_name}` was left naming a key that had
  become `actionName` and interpolation silently produced nothing. Ten
  multi-word placeholders were affected: `%{action_name}`, `%{allowed_fields}`,
  `%{error_type}`, `%{expected_keys}`, `%{expected_members}`,
  `%{extra_fields}`, `%{field_type}`, `%{found_keys}`, `%{provided_keys}` and
  `%{return_type}`. A client that hardcodes a snake_case placeholder name must
  now read the key from `vars`.

### Added

- `mix ash_introspection.upgrade`
  ([#34](https://github.com/udin-io/ash_introspection/issues/34)) — the
  Igniter task carrying a codemod per breaking release, so
  `mix igniter.upgrade ash_introspection` migrates consumer code instead of
  leaving it to a hand search.
- `AshIntrospection.ErrorFormatter.format/2` — formats an error's keys and
  rewrites its placeholders in one pass, which is the only way the two can stay
  consistent.
- `AshIntrospection.FieldFormatter.format_output_field_names/2` — the
  recursive key walk the RPC pipeline used privately, now shared so error
  payloads and the response envelope agree.
- `config :ash_introspection, :policies, show_policy_breakdowns?: true` — opt
  in to sending the policy breakdown back as the forbidden error's message.
  Deliberately a separate setting from Ash's own `:ash, :policies`, so an
  app-wide development toggle cannot open RPC responses in production.
- `AshIntrospection.FieldFormatter.resolve_field_name/2` — resolves a field
  name to an existing atom, or returns the formatted string when none exists.
- `AshIntrospection.Rpc.FieldProcessing.Validation.field_exists?/2` — field
  existence check that accepts a string name, which `Keyword.has_key?/2`
  rejects.

### Fixed

- String field names on a resource with no interop name mapping resolved to
  `nil`, so valid names were rejected and unknown ones reported as
  `{:unknown_field, nil, resource, path}`.

### Removed

- **Breaking:** `AshIntrospection.FieldFormatter.convert_to_field_atom/2`. Its
  contract was to always produce an atom, which is the vulnerability itself.
  Callers passing client input should use `resolve_field_name/2`; callers that
  genuinely hold a trusted name already have the atom.

## [0.2.0] - 2025-12-21

### Added

- Action introspection module (`AshIntrospection.Codegen.ActionIntrospection`)
  - Pagination support detection (offset/keyset)
  - Input type analysis (required/optional/none)
  - Return type analysis for generic actions
- Validation error types module
  (`AshIntrospection.Codegen.ValidationErrorTypes`)
  - Error type classification for code generation
  - Action input error classification
- Comprehensive documentation in README

### Changed

- Enhanced type discovery with better cycle detection
- Improved field selector validation

## [0.1.0] - 2025-11-25

### Added

- Initial release
- Core type system introspection (`AshIntrospection.TypeSystem.Introspection`)
  - Type classification and NewType unwrapping
  - Union type extraction
  - Field name callback detection
- Resource fields lookup (`AshIntrospection.TypeSystem.ResourceFields`)
- RPC pipeline for action execution (`AshIntrospection.Rpc.Pipeline`)
  - 4-stage execution: parse, execute, process, format
- Request structure (`AshIntrospection.Rpc.Request`)
- Value formatter for bidirectional type conversion
- Result processor with extraction templates
- Field processing modules
  - Atomizer for field name conversion
  - Field selector for recursive selection
  - Validation for duplicate detection
- Error handling modules
  - Error protocol for exception extraction
  - Error builder for message generation
  - Central error processing pipeline
- Type discovery for code generation (`AshIntrospection.Codegen.TypeDiscovery`)
- Field formatter utilities (camelCase, PascalCase, snake_case)
