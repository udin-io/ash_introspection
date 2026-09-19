<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# Decisions

The choices that still shape this library, newest first. One dated entry each:
what was decided, why, and what it cost. Written for issue #36, which noted
that the most important of them — the split from `ash_typescript` — was
recorded nowhere in the repo. This page replaces ADRs; there is no `adr/`
directory here and none should be created. A decision that no longer shapes the
code is deleted, not archived, because git keeps the history.

## 2026-09-19 — Relationships are decorated, because the manifest cannot say

**Decided.** `Manifest.Decorator` lists a resource's relationships live at
decoration time and stores a narrowed record for each — `name`, `destination`,
`cardinality`, `public?` — under the resource's payload, private relationships
included. `ResourceInfo.relationship/3` and `public_relationship/3` read those
records, and fall back to live introspection only for a resource the decorator
did not reach. Issue #23 stage 5a, PR 2.

**Why.** Both readers had an answer no manifest can give.
`Ash.Info.Manifest.Generator` builds a resource's relationships from
`public_relationships/1` unless `include_private_relationships?: true` is
passed (`deps/ash/lib/ash/info/manifest/generator/resource_builder.ex:271`),
and `%Ash.Info.Manifest{}` records **no build options** at all: its six fields
are `resources`, `types`, `entrypoints`, `filter_capabilities`,
`sort_capabilities` and `custom` (`deps/ash/lib/ash/info/manifest.ex:40`). So a
reader holding a manifest cannot tell a resource that declares no private
relationships from a manifest built without them, and `relationship/3` fell
back to live for every private relationship with nothing saying so. The public
reader was worse than slow: `%Ash.Info.Manifest.Relationship{}` carries no
`public?`, so on a manifest built **with** private relationships —
`ash_kotlin_multiplatform`'s, at `build_manifest.ex:69` — the manifest's own
map handed a private relationship back as public.

**What it cost.** A relationship's decoration now lives in two places. The
narrowed records hang off the resource, because a private relationship has no
`%Manifest.Relationship{}` to carry a `custom` map; stage 2's pagination and
read-action payload stays on that struct, because #24 asks it only of a
relationship a client can select. Neither answers the other's question, so
there is no second path to drift — but a reader has to know which one it wants.
Measured on `ash_kotlin_multiplatform`'s manifest at `4a50811`: 8 records over
7 resources, +2004 bytes of a 911,459-byte term, 0.22%.

The alternative — moving pagination onto the records too, one home for all of
it — was rejected here: it changes the signature of the public
`Custom.relationship_pagination/2`, and this PR ships additively in 0.5.3
beside PR 1.

## 2026-09-18 — A tuple template entry is a map that carries its index

**Decided.** Every entry `FieldSelector` emits for a tuple field is a map,
`%{field_name: atom, index: n}`, with `nested: [...]` added when the field was
selected with inner fields. A tuple is the only container read by position,
so its entries are the only ones that carry one, and they carry it whether or
not they also carry a nested template. `FieldExtractor` places the element;
`ResultProcessor` applies `:nested`. Issue #66.

**Why.** #35, #84 and #66 are one family: a producer in `FieldSelector`
emitted an entry no consumer matched, and every consumer ends its `case` with
a catch-all that drops the entry in silence, so the field arrived missing or
`nil` with no error. #35 was a string key in a tuple entry, #84 a string key
in a union member entry, #66 a tuple entry with no index. The rule that
closes the family: a template key is the resolved atom, a tuple entry is a map
with `:index`, and a new shape lands with its reader in the same commit.

**What it cost.** `FieldSelector.process/4` returns a map where it returned a
`{atom, nested}` 2-tuple, for a nested tuple field only. The consumer passes
the template through unread (`ash_kotlin_multiplatform` `runner.ex:188-205`
at `16c3717`), so 0.5.2 is additive. The alternative — reading positions from
the `fields` constraint inside `ResultProcessor` and leaving `index` unread —
was rejected: it keeps a public key nothing reads.

## 2026-09-17 — A top-level union is typed by its action, with no fallback

**Decided.** `ResultProcessor.determine_data_type/3` reads a top-level
`%Ash.Union{}`'s members only from `config[:action_returns]`, which
`Pipeline.process_result/3` sets for every generic action. The old lookup,
`get_union_constraints_from_resource/2`, is deleted rather than kept as a
fallback. Issue #84.

**Why.** The old lookup read the owning resource's first union attribute,
which has no relation to the action. In `Test.Shelf`, `:badge` comes first and
names `:summary` as a string, so the action's embedded `:summary` member came
back with every attribute and its `:counts` member with an undeclared key. A
fallback to it is wrong whenever it answers at all, and it answers silently.

**What it cost.** A caller of `ResultProcessor.process/4` that does not go
through `Pipeline.process_result/3` and does not pass `:action_returns` now gets
untyped union members: each member value normalised with no field selection.
Before, it got the first attribute's types, which were right only when that
attribute happened to match. `ash_kotlin_multiplatform` calls `process/4`
nowhere in its `lib/` (grep at `41c6bef`). Named in the CHANGELOG.

## 2026-09-17 — Delete `Codegen.TypeDiscovery`; codegen reads the manifest only

**Decided.** 0.5.0 deletes `AshIntrospection.Codegen.TypeDiscovery`, 1109
lines, with no replacement in this library. A client generator reads the types
it needs from a generated `%Ash.Info.Manifest{}`: embedded resources are the
`manifest.types` entries whose `kind` is `:embedded_resource`, and resources
are `manifest.resources`. Five functions go with the module and have no
replacement: `find_resources_missing_from_rpc_config/2`,
`find_non_rpc_referenced_resources/2`,
`find_non_rpc_referenced_resources_with_paths/2`,
`build_missing_config_warning/3` and `build_non_rpc_references_warning/2`.
Issue #23 stage 4b. `mix ash_introspection.upgrade` prints a notice for 0.5.0
naming all of it.

**Why now.** Stage 4 was split so the deletion would wait for evidence: a real
consumer generating from the manifest. `ash_kotlin_multiplatform` PR #86
(`70671e8`) moved its codegen onto `manifest.types`, and PR #83 deleted its own
copy of the traversal. At `70671e8`, grep of its `lib/` and `test/` finds
`TypeDiscovery` nowhere, and `mix xref callers
AshIntrospection.Codegen.TypeDiscovery` returns nothing. Until this change
`test/ash_introspection/manifest/codegen_differential_test.exs` compared the
module's live and manifest answers 423 times, byte for byte, and they agreed.

**Why a wider answer is accepted.** Two measurements, and they say different
things:

- Over this repo's fixtures the module and `manifest.types` found the same 7
  embedded resources, 0 different in either direction (measured 2026-09-17 at
  `5dc9e85`).
- In the consumer, its old one-level attribute walk found 1 embedded resource
  over PR #86's fixtures and the manifest found 8. Before that PR the
  generated Kotlin named three types it never declared.

So the manifest is at least as wide as the deleted module here, and much wider
than the consumer's own walk. `Reachability` follows action arguments,
accepted attributes and relationships; a client that names a type has to
declare it, so wider is the correct direction.

**Why the warnings go.** They reported resources a consumer had not declared.
A manifest carries only what was declared, so it cannot answer that, and
keeping them would have kept a live `Ash.Info.domains/1` scan alive for two
warnings no consumer calls.

**What else this retires.** The 2026-09-13 decision that a manifest's sorted
entrypoints reorder discovery output compared a manifest config with a
callback config. With the module gone there is one order, the manifest's, and
the consumer sorts embedded classes by module name.

**Cost.** Breaking, and the consumer's `~> 0.4` excludes 0.5.0, so it takes
this release only through a deliberate bump. The differential test went with
the module it compared, so "the manifest answers correctly" is now Ash's claim
and not a measurement here. The suite drops 26 tests net, 477 to 451. The route
fixtures in `test/support/discovery_resources.ex` stay as manifest inputs, but
no test here names them. And an embedded resource reached only through a
`first` aggregate is in neither the consumer's old answer nor the manifest; its
PR #86 pins that upstream Ash gap with a test.

## 2026-09-11 — The decoration carries Ash's structs, it does not rebuild them

**Decided.** `AshIntrospection.Manifest.Decorator` captures the live
`%Ash.Resource.Attribute{}`, `%Ash.Resource.Calculation{}`,
`%Ash.Resource.Aggregate{}` and action structs and stores them under
`custom.<namespace>`. It does not translate them into anything of its own, and
it does not read `%Ash.Info.Manifest.Field{}` in their place. Issue #23 stage
2.

**Why.** A manifest field is a *client-facing* description. It carries a
resolved `%Ash.Info.Manifest.Type{}` where every caller here reads `.type` plus
a `.constraints` keyword list, and `has_default?` where they read `.default` —
a value the manifest does not carry at all. Two callers go further and depend
on the struct itself: `Codegen.ActionIntrospection` pattern-matches
`%Ash.Resource.Attribute{}` to decide whether an input is required, and
`Codegen.ValidationErrorTypes.classify_action_input_errors/3` hands the struct
back to its caller. Rebuilding would be lossy *and* breaking, in a stage whose
whole claim is that it is neither.

So the decorator only *computes* what is genuinely derived and genuinely
repeated per request: resolved aggregate types, return classifications, the
bulk-authorization strategy, client-facing field and argument names under each
built-in formatter with their reverses, per-relationship pagination, and the
entrypoint lookup. Everything else is a captured pointer.

**Cost.** The decoration is bigger than it needs to be, and it is a snapshot: a
resource recompiled without the manifest recompiling leaves stale structs
behind. That is the staleness upstream's `8c07331` exists to prevent, and it
belongs to the consumer's compile edges — stage 3 — because a pure function
of its arguments cannot own a dependency graph. It also means the win is
smaller than "stop introspecting": the request path stops *walking*, it does
not stop *holding*. And moving to manifest-shaped return values later is a
breaking change this stage deferred rather than avoided; it belongs with stage
5, which makes the manifest required on the request path.

## 2026-09-11 — The `custom` namespace is a parameter, not a constant

**Decided.** Every function in `AshIntrospection.Manifest.Decorator` and
`AshIntrospection.Manifest.Custom` takes the namespace as a trailing argument
defaulting to `:ash_introspection`, and `ResourceInfo.Source` carries the one a
read should use. An optional `:manifest_namespace` config key sets it. Issue
#23 stage 2.

**Why.** `Ash.Info.Manifest` leaves a `custom` map on every struct so each
client library can hang its own precomputed data off one manifest. Whether the
generators built on this core share a single decoration or each take their own
key is a real question with no answer yet: sharing is cheaper and couples every
generator's client-name rules together, and separating is the split this
library exists to enable. Stage 2 does not need to settle it, and settling it
by hard-coding a constant would settle it silently. A parameter answers both,
and `decorator_test.exs` proves two namespaces coexist on one manifest.

**Cost.** Every public function in both modules gained an argument, and the
`Source` struct gained a field. A caller that prepares a source under one
namespace and reads under another gets the fallback rather than an error: the
reads answer live, correctly and more slowly, and nothing says why. That is the
same silence the decorator's skip has, for the same reason — an undecorated
read is a correct read.

## 2026-09-11 — A failed error protocol gets a log line, not a wire id

**Decided.** When `ErrorProtocol.to_error/1` raises, throws or exits, the
private `protocol_failure/3` in `AshIntrospection.Rpc.Errors` returns the
`"something went wrong"` fallback the raising case already returned and adds no
identifier to it. The log line is the only link between the response the client
holds and the failure that produced it, so it carries the implementation
module, the kind and reason, the original error and the stacktrace. Issue #40,
commit `99cdbd4`.

**Why.** The fallback is the response shape consumers already receive. Adding
an error id to it changes the wire for every client, and a generated Kotlin or
TypeScript client is regenerated rather than migrated — the cost #14 and #34
paid for renaming one key. The fix was worth taking on its own: before it, a
throw or exit out of a protocol implementation escaped `to_errors/6` and took
the request with it. Widening the catch is a strict improvement; widening the
payload is a breaking release.

**Cost.** An operator holding a client's "something went wrong" cannot join it
to a log line by id. They match on time and on the action in the request. That
is worse than an id and it is the price of leaving the wire alone; a future
release that already breaks the error payload is the place to revisit it.

## 2026-09-11 — The case predicates walk bytes, quirks and all

**Decided.** `FieldFormatter`'s `is_camel_case?/1`, `is_pascal_case?/1` and
`is_snake_case?/1` match on the binary instead of running a regex, and they
reproduce two PCRE quirks of the regexes they replace rather than correcting
them: the character classes stay ASCII-only, because the old regexes carried no
`u` flag, and a single trailing newline is still accepted, because PCRE's `$`
matches before one. Issue #61, filed out of #26.

**Why.** #26 found the cost of `format_field_name/2` is the predicate, not the
conversion. Re-measured 2026-09-11 at `74afafd` on OTP 27 / Elixir 1.18.4,
warmed loops through `:timer.tc/1`, five runs each: one `String.match?/2` call
costs 280-370 ns, `Macro.camelize/1` — the work that transforms the name —
costs 59-72 ns, and the binary walk costs 7-10 ns. #26's figures reproduced.
Before and after, back to back on one machine:

| Call | Before | After |
|---|---|---|
| `format_field_name(:user_name, :camel_case)` | 453-472 ns | 156-170 ns |
| `format_field_name("user_name", :camel_case)` | 441-451 ns | 141-146 ns |
| `format_field_name("userName", :camel_case)` | 585-607 ns | 12 ns |
| `format_field_name("success", :camel_case)` | 773-783 ns | 130-142 ns |
| `format_field_name(:user_name, :pascal_case)` | 317-321 ns | 76-92 ns |
| `format_field_name(:user_name, :snake_case)` | 355-363 ns | 24-28 ns |

The same laptop reads 15% apart between runs, so the ratio is the number to
trust, not the nanoseconds. Every caller pays it — the RPC output path,
codegen and error formatting — and unlike the cache #26 declined it reaches
the `"success"` and `"data"` envelope literals, 2 of the 6 calls per record.

**Why keep the quirks.** They are behaviour, and behaviour is what a
performance change may not touch. `"userN\n"` is camelCase to the old regex and
stays camelCase now; `ünter` was never lowercase to `[a-z]` and still is not.
Correcting either is a separate decision with its own entry, taken on purpose
rather than as a side effect of a rewrite.

**Cost.** Two things a later reader will want to delete and should not.
`test/ash_introspection/field_formatter_case_predicate_equivalence_test.exs`
carries a frozen copy of the three regexes as an oracle — the only way to
assert the answers did not move. And it reaches for `:erts_debug.same/2`,
because half of the equivalence is invisible to a value assertion: every name a
predicate accepts is a fixed point of the conversion it skips (checked over
4681 names), so a predicate that wrongly answers `false` still produces the
right string, by the slow route. What separates the two paths is the term —
`format_field_name/2` returns the binary it was handed when the predicate
accepts, and builds a new one when it converts.

## 2026-09-11 — One reader for introspection, and `resource?/1` split in two

**Decided.** Every `Ash.Resource.Info` call in `lib/` — 64 of them at
`74afafd`, across nine modules — goes through
`AshIntrospection.ResourceInfo`, which reads an optional `:manifest` key off
the config map the pipeline and codegen already thread. Omitting the key reads
live introspection exactly as before. This is stage 1 of five for issue #23;
the staged plan is in [roadmap.md](roadmap.md).

**Why one reader.** The alternative was to migrate the 64 sites to the manifest
in one change. That is a diff nobody can review, and it couples the seam to the
translation: if the manifest turns out to answer a question differently, the
whole thing has to come back out. With the reader in place, stage 2 changes one
module and stage 5 deletes a branch in it. The compatibility guarantee is
testable rather than asserted — `resource_info_test.exs` compares every read
against `Ash.Resource.Info` itself, and `pipeline_manifest_parity_test.exs`
runs the same request twice and compares the responses.

**Why `resource?/1` is two functions.** `Ash.Resource.Info.resource?/1` answers
a fact about a module. `Ash.Info.Manifest.has_resource?/2` answers a fact about
the declared API surface. Eighteen of the 64 sites ask that question, so the
reader exposes both readings and makes each call site choose:

- `runtime_resource?/2` falls back to live introspection when the manifest does
  not carry the module. Every request-path site uses it. Four of them classify
  a runtime `value.__struct__`, and answering `false` for a struct Ash actually
  handed back would drop it into `ResultProcessor`'s generic
  `Map.from_struct/1` branch — a different response body, with no error.
- `declared_resource?/2` treats absence as the answer. Codegen uses it, because
  scoping to what was declared is the whole point of generating against a
  manifest.

Both count embedded resources. `Ash.Info.Manifest.Generator` splits them out of
`resources` and files them under `types` with `kind: :embedded_resource`
(`deps/ash/lib/ash/info/manifest/generator.ex:110`), so a bare `has_resource?/2`
would answer `false` for every one of them — a divergence from live
introspection that has nothing to do with scoping.

**What stage 1 did not do, and stage 2 did.** Stage 1's readers for attributes,
calculations, aggregates and actions took a config and ignored it: they
answered live whether or not a manifest was present.
`%Ash.Info.Manifest.Field{}` carries a resolved `%Ash.Info.Manifest.Type{}`
where `%Ash.Resource.Attribute{}` carries an Ash type module plus a constraints
keyword list, and translating between the two was stage 2's decorator, with its
own failure modes. Half-translating it in stage 1 would have put a second,
quieter answer beside the live one. Those readers now route through the
decoration — see the two entries at the top of this page — and the reader's
moduledoc still lists what is answered from where.

**Cost.** Two functions where the domain has one concept, and a call site that
picks the wrong one fails silently in exactly the way the split exists to
prevent. The rule — fallback by default, `declared_resource?/2` only where the
site is unambiguously codegen — is written in the reader's moduledoc and
nothing enforces it. Six public functions gained an optional trailing argument,
which is additive but widens the surface `ash_kotlin_multiplatform` depends on.
`Codegen.TypeDiscovery` routed its 14 reads and was handed no config, so it
could not read a manifest even when one was supplied; stage 4a threaded the
config through, and stage 4b deleted the module in 0.5.0. And the reader narrows
two return shapes
the two sources cannot share — `relationship/3` and `identity_keys/3` return
only the keys this library reads, so a future caller wanting
`%Ash.Resource.Relationships.HasOne{}.writable?` has to widen them first.

## 2026-09-09 — Load restrictions ride on the config map, not a manifest

**Decided.** `allowed_loads` / `denied_loads` reach field selection through an
optional `:load_restrictions` key on the config map that
`FieldSelector.process/4` already takes, the same shape `:is_interop_resource?`
and `get_rpc_action_entrypoints` use. Upstream `ash_typescript` reads them from
`Ash.Info.Manifest` instead. Issue #19.

**Why.** This library has not adopted the manifest and will not for a while
(#23, below). Waiting for it would have left every generator built on this core
unable to shape an action's loadable surface, which is why
`ash_kotlin_multiplatform` shipped without the feature. The config map is
already threaded to every point that appends to the load statement, so the
value arrives where the check happens with no new plumbing, and omitting the
key means `:none`, so no existing caller changes behaviour.

**Also decided:** restrictions are checked **during** field selection, at each
of the six points where `FieldSelector` appends to the load statement, rather
than by walking the finished load statement. A separate traversal has to
re-derive which parts of a load list are loads and which are selects, and
upstream's did: nested scalar loads escaped it entirely until `3aaae6b`. A
check at the append site cannot disagree with field selection about what is
being loaded, because it is field selection.

**Cost.** A second place restrictions can come from once #23 lands, and someone
will have to decide whether the manifest supersedes the config key or feeds it.
The config key is also unvalidated: a typo in a field name is a path that
matches nothing, which under `{:deny, ...}` silently restricts nothing. A
manifest-backed DSL would catch that at compile time. And this is an API
surface tool, not authorization — Ash policies still apply to every load that
gets through, which the moduledoc says plainly because the failure mode of
believing otherwise is a security hole.
## 2026-09-09 — No compile-time field-name cache: nothing to attach it to

**Decided.** Do not port upstream `ash_typescript`'s `PersistFormattedFields`
Spark transformer (`b2d30bf`), and do not build a variant of it here. Issue #26
is closed as decided against. The measurement below is the evidence; re-run it
before reopening.

**Why — the transformer cannot exist in this library.** A Spark transformer is
listed in a `use Spark.Dsl.Extension` call, and **this library ships no DSL of
its own**: `grep 'use Spark.Dsl.Extension' lib` returns nothing, and the only
extension in the tree is the test-only `AshIntrospection.Test.RpcDsl`.
Upstream's transformer body reads `[:typescript], :field_names` off the
resource's DSL state, a section this library neither owns nor can name. The
equivalent mapping lives entirely in the consumer:
`ash_kotlin_multiplatform` holds it in
`AshKotlinMultiplatform.Resource.Info.kotlin_field_names/1` and injects the
lookup as the `:format_field_for_client` closure in the pipeline config. There
is no public `format_field_for_client/3` here at all — only the private
`ValueFormatter.format_field_for_client/4`, which calls the consumer's closure
or falls back to `FieldFormatter.format_field_name/2`. A cache the core owns
cannot see inside a closure the consumer supplies.

**Why — the cost the ticket describes is not the cost this library has.** The
ticket quotes upstream's ~1,500 calls of one `(field, resource, formatter)`
triple per sync. Measured here at `0dd9ac5`, OTP 27 and Elixir 1.18.4, over 100
single-record RPC runs against `AshIntrospection.Test.Account` with four public
fields selected, each run passing through `execute_ash_action/1`,
`process_result/3` and `format_output_with_request/3`. Call counts come from
`:erlang.trace/3` on `{FieldFormatter, :format_field_name, 2}`, timings from
`:timer.tc/1` on warmed loops; the ranges are five runs on one laptop, so read
the shares, not the milliseconds:

| Measurement | Value |
|---|---|
| `format_field_name/2` calls | 6 per record — 4 field names, plus `"success"` and `"data"` |
| `format_field_name/2` cost | ~470 ns per call, warm |
| Time in `format_field_name/2` | 0.65–0.82 ms per 100-record run |
| `execute_ash_action/1` | 32–42 ms (320–420 µs per record) |
| `process_result/3` | 0.44–0.55 ms |
| `format_output_with_request/3` | 1.15–1.48 ms |
| Share of the output-formatting stage | 53–59% |
| **Share of the whole pipeline** | **1.7–2.1%** |

A perfect cache replaces ~470 ns with a ~7 ns map lookup, so ~2% of pipeline
wall clock is the ceiling on the entire idea. Ash action execution is 95% of it.

**Why — a transformer would reach only two thirds of even that.** Tracing the
arguments of all six calls for one record: four are resource field atoms, which
a transformer could persist. `"success"` and `"data"` are string literals in
the response envelope, formatted on every response and belonging to no
resource. No resource-attached cache reaches them.

**What we found instead.** The cost is not the missing cache, it is the
predicate. `format_field_name/2` runs `is_camel_case?/1`, `is_pascal_case?/1`
or `is_snake_case?/1`, each one or two `String.match?/2` calls against a regex.
One `String.match?/2` measures ~295 ns; a binary-walk clause computing the same
answer measures ~10 ns; and `Macro.camelize/1`, the work that actually
transforms the name, is only ~60 ns. Replacing the three predicates would cut
the function to roughly 130 ns for every caller, resource field or not, with no
extension, no transformer and no consumer wiring. That is filed as its own
issue rather than folded into this one: those predicates decide casing
behaviour across the whole library, and a faithful rewrite needs equivalence
tests of its own. It shipped as #61 — see the 2026-09-11 entry at the top of
this page for the before-and-after numbers.

**Cost.** Upstream drift widens by one more commit, and this drift is invisible
in a diff — a reader comparing the two trees sees a transformer that is
missing, not one that was declined. This entry is the marker. If #23 lands and
the library adopts `Ash.Info.Manifest`, upstream's successor to this work is
`Manifest.Custom.formatted_field_names`, which arrives with the manifest for
free. That is the second reason not to build a bespoke mechanism now.

## 2026-09-09 — The metadata allowlist stays with the caller

**Decided.** This pipeline extracts exactly the metadata fields
`Request.show_metadata` names. Deciding **which** fields a client may ask for
was left out on purpose. Issue #20.

**Why.** There is nothing here to hang it on. Upstream `ash_typescript`
filters the requested list in its parse stage; this library has no parse
stage, because `parse_request/3` lives in each language-specific wrapper.
Building one to hold a single check would duplicate a stage that already
exists downstream, and `ash_kotlin_multiplatform`'s `Rpc.Runner` already has
the check: `dsl_metadata_fields/2` reads the allowlist off the RPC DSL and
`narrow_metadata_fields/2` intersects the client's request with it, so a
client can only narrow, never widen.

**Cost.** A responsibility that is documented rather than enforced. A future
wrapper that pipes client input into `Request.show_metadata` unfiltered
exposes every metadata field its actions declare, and nothing here stops it or
says so at compile time. The "Action metadata" section of `Rpc.Pipeline`'s
`@moduledoc` names the obligation; that is the whole of the enforcement.

## 2026-09-09 — Metadata is formatted by its declared type

**Decided.** An action's metadata values are formatted once, at extraction, by
the type the action declared for them — the same `ValueFormatter` dispatch an
attribute goes through. The response envelope then formats the top-level
metadata name and nothing below it. A metadata field declared as an
unconstrained `:map` reaches the client verbatim. Issue #20.

**Why.** The type is only knowable at extraction. A metadata name is not an
attribute, so the stage-4 resource lookup finds nothing and passes the value
through — which is how a typed map's nested keys reached the client in
snake_case inside a camelCase response. Moving the formatting to where the
declaration is readable fixes that, and it forces the envelope to stop
recursing, because formatting a value twice is not idempotent in general: a
field pinned to the client name `_rev` came out as `rev`.

Unconstrained maps are excluded because declaring `:map` with no field
constraints is a statement, not an omission. The caller said the shape is not
the type system's business; renaming its keys contradicts that, and the keys
that get renamed — `_id`, `_rev`, anything with a leading underscore — are
exactly the wire names a client cannot reconstruct.

**Cost.** The guarantee is narrower than the pipeline's output surface. It
holds on `format_output_with_request/3`, which has the types, and not on
`format_output/2`, which does not — and `format_output/2` is what
`ash_kotlin_multiplatform` calls. See risk T4 in [risks.md](risks.md).
## 2026-09-09 — The writable test resource gets a private ETS table

**Decided.** `AshIntrospection.Test.Account` declares `ets do private?(true)
end`, and the five test files that write to it no longer call
`Ash.DataLayer.Ets.stop/1` from `on_exit`. Issue #55.

**Why.** Without `private?`, the Ets data layer keeps one named table for the
whole VM behind a `TableManager` GenServer, so the only way to empty it between
tests was `stop/1` — which sends that GenServer `Process.exit(pid, :shutdown)`
and returns. The kill is asynchronous, so the next test's `setup` could wrap
the table before the VM reaped it and then write to a dead reference. `mix
test` failed 5 times in 200 runs on `main`; the file that carried most of it,
`pipeline_filter_injection_test.exs`, failed 11 times in 200 runs of that one
file alone. `private?` moves the isolation into the data layer: each test
process gets its own unnamed table, reaped when the process exits, so there is
nothing left to tear down and nothing shared to race on.

**Cost.** A private table is visible only to the process that created it. A
test that writes `Account` from a spawned process, a `Task`, or a `setup_all`
block will see an empty table rather than the records it just wrote. That is
the trade for the isolation, and it is recorded in [`CLAUDE.md`](../CLAUDE.md).
It also turns off the Ash async engine for this resource
(`Ash.DataLayer.Ets.can?/2` answers `false` for `:async_engine` when
`private?`), which nothing here depends on.

## 2026-09-09 — `identity` is an update/destroy key; reads reject it

**Decided.** A read action carrying `identity` fails with
`identity_not_supported` naming the action. Reads select a record with
`get_by`. Wiring `identity` into the read path was rejected. Issue #44.

**Why.** Upstream `ash_typescript` already means this. Its `identities` option
resolves to `[]` for every action type but `:update` and `:destroy`
(`lib/ash_typescript/rpc/codegen/helpers/config_builder.ex:63-67`), so the
field is emitted into neither the generated config type nor the request
payload, and no generated client can send it on a read. This library exists to
be the shared core of that design, so the alternative — teaching reads a
lookup key upstream does not have — was the divergence, not the rejection.

It would also have needed rules upstream has never written. `identities`
defaults to `[:_primary_key]`, and `maybe_apply_identity_filter/5` errors with
`missing_identity` when the identity is absent but the list is not empty. Reads
would have needed their own default of `[]`, so the symmetry with update and
destroy was never real.

Rejecting is what removes the silence the ticket was filed about. The old
behaviour built no filter: the caller named one record and got the whole table,
or a `MultipleResults` from `Ash.read_one/1` naming nothing it could act on.
That is not hypothetical — `ash_kotlin_multiplatform`'s Swift generator sends
it. `generate_get_function/3` emits `identity: id` for `get?` reads
(`lib/ash_kotlin_multiplatform/swift/codegen.ex:581-594`), so every generated
Swift `getX(id:)` call is broken today. Its Kotlin generator gates on the same
empty list upstream does and never sends it.

**Cost.** A generated Swift client that compiles now fails at runtime with a
named error instead of returning the wrong record, so
`ash_kotlin_multiplatform` has to move those reads to `get_by` before it takes
this release. That is the point — the failure was already there and was
silent — but it is a real break for a consumer that is not covered by any
test here. Same release also stops accepting a null identity value: it compiled
to `key == nil`, which Ash evaluates as unknown, and building `is_nil(key)`
instead would let a null key match several records, since Ash identities
default to `nils_distinct?: true` and update and destroy take
`Ash.Query.limit(query, 1)`.

## 2026-09-09 — Unify RPC error payloads on `type`, and ship a codemod with it

**Decided.** Every RPC error names its class under `type`. The `code` key is
gone. The breaking release carries `mix ash_introspection.upgrade`, an Igniter
task that rewrites consumer code reading `code` off an error and prints the
shapes it cannot decide. Issues #14 and #34, commit `b273f70`.

**Why.** The `AshIntrospection.Rpc.Error` protocol already emitted `type`, but
the fallback paths in `AshIntrospection.Rpc.Errors` emitted `code`. A client
reading `error.type` got `nil` for exactly the errors it could not anticipate:
an exception with no protocol implementation, an implementation that raised,
and a domain with `show_raised_errors?` set. One name or the other had to go,
and `type` was the one the protocol already promised.

**Cost.** A breaking release for the only consumer, and the codemod itself —
a Mix task, an Igniter dev/test dependency, and a test suite for the task. The
codemod cannot reach generated TypeScript or Kotlin clients, which are
regenerated by hand. Writing it also surfaced the
`Igniter.update_all_elixir_files/2` trap recorded in
[`CLAUDE.md`](../CLAUDE.md).

## 2026-09-09 — Raise the `ash` floor to `~> 3.33`, not upstream's 3.32.3

**Decided.** `mix.exs` requires `{:ash, "~> 3.33"}`. Issue #28, commit
`966f1d6`.

**Why.** A library's floor is what its consumers inherit, so the floor — not
the lock — is the security-relevant number. `ash` 3.33.0 is the first release
carrying the fix for CVE-2026-82752, where string length constraints counted
graphemes and a combining-mark string of any size passed `max_length`.
Following upstream `ash_typescript` to 3.32.3 would have left every consumer of
this library free to resolve a vulnerable `ash`.

**Cost.** A consumer on an older `ash` cannot take this release without
upgrading. It also forced a decision this library would rather not make for
its users: `ash` 3.33.0 refuses to compile a resource until the host states how
string length is counted, so `config/config.exs` sets
`default_string_length_count: :codepoints` for the test resources compiled
here, and `mix.exs` keeps `config` out of the published `files` list so
consumers stay free to choose.

## 2026-09-09 — Teach the formatter about the Ash and Spark DSLs

**Decided.** `.formatter.exs` carries `import_deps: [:ash, :spark]`, and CI
enforces `mix format --check-formatted`. Issue #30, commit `c4a4448`.

**Why.** Without the imports, `mix format` did not know the DSL macros and
rewrote unrelated regions of any file it touched. `main` was not
formatter-clean, so the blast radius of an accidental format was large and easy
to miss in review — several pull requests that week had to hand-revert churn.

**Cost.** One reformatting pass across the tree, and the discipline of a
`--check-formatted` gate on every pull request. The related trap — that
`mix format --stdin-filename <path> < file` blanket-formats the whole `inputs`
glob when given no file argument — is recorded in [`CLAUDE.md`](../CLAUDE.md),
because the formatter config does not fix it.

## 2025-12-20 — ETS-only test data layer, no database

**Decided.** `test/support/*.ex` declares `data_layer: Ash.DataLayer.Ets` on
every test resource. There is no repo, no `priv/repo/migrations`, and no
database setup step.

**Why.** This library never persists anything. It introspects resources and
transforms values on the way in and out of an Ash action, and the action's data
layer is the consumer's problem. An ETS layer exercises every code path this
library owns while keeping `mix test` a single command with no service to
start.

**Cost.** Nothing here proves the pipeline against a SQL data layer, so
behaviour that depends on one — how a real adapter counts string length,
how it orders a keyset page — is untested at this layer and only surfaces in
a consumer. It also means the standard per-worktree partition-database workflow
does not apply to this repo, which is recorded in [`CLAUDE.md`](../CLAUDE.md)
so no session sets one up by habit.

## 2025-12-20 — Defer `Ash.Info.Manifest`; keep live introspection for now

**Decided.** Continue calling `Ash.Resource.Info` at run and compile time
rather than adopting the precomputed `Ash.Info.Manifest` that upstream moved
to in `ash` 3.32.3. Tracked as issue #23.

**Why.** The manifest is a Spark DSL module the *host application* declares and
registers in config; codegen and the runtime pipeline both raise without it.
Adopting it is a breaking change for every consumer and a rewrite of the type
discovery layer, not a refactor. At the time the library had one consumer and
no tests on the RPC layer, so the sequencing put security fixes first.

**Cost.** This is the main source of upstream drift, and the reason upstream's
type-discovery fixes do not port cleanly here. Roughly a dozen backlog items
sit behind #23. The debt grows with every upstream release — see
[risks.md](risks.md), T1.

**Superseded in part on 2026-09-11.** The reasoning above still holds for the
manifest *module*, which stays in the consumer. What changed is that the
library now accepts one: see the entry at the top of this page.

## 2025-11-25 — Extract the shared core out of `ash_typescript` by copying it

**Decided.** `ash_introspection` was created by copying `ash_typescript`'s
language-agnostic core — type introspection, the four-stage RPC pipeline,
field-name mapping, value formatting and error handling — into a new package
under `udin-io`. `ash_typescript` was left alone: it does not depend on this
library, and this library does not depend on it.

**Why.** `ash_kotlin_multiplatform` needed the same pipeline, and reproducing
it would have meant maintaining two implementations of the same protocol.
Making `ash_typescript` depend on a new, unproven package was not ours to
decide: it belongs to `ash-project`, ships to real users, and a shared
dependency would have made every change here a change to its release.

**Cost.** Two copies of the same code, drifting. Every upstream fix is a manual
port, and the ports have already stopped being mechanical (see the
`Ash.Info.Manifest` entry above). This is the single largest ongoing cost the
project carries, and it is the trade that made the Kotlin generator possible at
all.

## Keeping this page current

A pull request that makes a choice a future reader would question adds an entry
here in the same pull request: the date, the decision, the reason, and what it
cost. "What it cost" is the part that is worth the page — a decision recorded
without its price reads as free, and the next person reverses it without
knowing what they are buying back.
