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
triple per sync. Measured here on `main` at `007eedd`, OTP 27 and Elixir
1.18.4, over 100 single-record RPC runs against `AshIntrospection.Test.Account`
with four public fields selected, each run passing through
`execute_ash_action/1`, `process_result/3` and `format_output_with_request/3`:

| Measurement | Value |
|---|---|
| `format_field_name/2` calls | 6 per record — 4 field names, plus `"success"` and `"data"` |
| `format_field_name/2` cost | ~470 ns per call, warm |
| Time in `format_field_name/2` | 0.73 ms per 100-record run |
| `execute_ash_action/1` | 41.0 ms (410 µs per record) |
| `process_result/3` | 0.55 ms |
| `format_output_with_request/3` | 1.39 ms |
| Share of the output-formatting stage | 53% |
| **Share of the whole pipeline** | **1.7%** |

A perfect cache replaces ~470 ns with a ~7 ns map lookup, so 1.7% of pipeline
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
tests of its own.

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
