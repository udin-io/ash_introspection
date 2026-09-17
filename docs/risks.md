<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# Risks

What could go wrong with this library, what we watch to see it coming, and what
we would do about it. Written for issue #36, which found the repo had no
statement of its exposure even though every fix here lands in a downstream
consumer's production. Each risk names the file or command that would show it,
so a reader can check the risk rather than take this page's word for it.

## Technical

### T1 — Drift from upstream `ash_typescript`

**The risk.** This library is a copy of `ash_typescript`'s shared core, not a
dependency of it. Upstream is at 0.18.2 and moves independently. Every fix
upstream makes to the pipeline, the field selector or type discovery has to be
ported by hand, and the two implementations have already diverged enough that
the port is not mechanical: upstream replaced live `Ash.Resource.Info`
introspection with `Ash.Info.Manifest` in `ash` 3.32.3, while this repo still
does it live at 64 call sites (#23, measured at `74afafd`). Since stage 1 of
#23 all 64 read through `AshIntrospection.ResourceInfo`, and since stage 2
those reads answer out of a decorated manifest when one is supplied. Stage 3
shipped in `ash_kotlin_multiplatform` (its PR #75, `e5ad024`), so a manifest is
now built, and since stage 4b the consumer's codegen reads its types straight
off it: this repo's `Codegen.TypeDiscovery` is deleted. The request path does
not read one — nothing in this repo puts a manifest on the pipeline config, so
every RPC read in production is live.

**Why it bites.** A bug fixed upstream stays live here, and it stays live in
`ash_kotlin_multiplatform`, which is what a real user runs.

**What we watch.** Upstream's changelog and commit range against the
extraction point. Issue #23 names the port set commit by commit. The backlog
items #19 through #26 are all upstream-parity work.

**What we would do.** Land #23 first so the introspection layers match, then
port the rest against the manifest instead of against live introspection.
Re-porting each fix onto live introspection is the expensive path and it is the
one we are on until #23 lands. Stages 1 and 2 shipped the seam and the
decorator that fills it, stage 3 the consumer's manifest, and stage 4 moved
codegen onto it. Stage 5, on [roadmap.md](roadmap.md), moves the request path
and closes the gap.

**A port was partial; the manifest closed it.** #21 landed the behaviour of
upstream `437901f` by hand, because upstream's own version of that commit calls
`Ash.Info.Manifest.Generator.Reachability` and there was nothing here to call.
The deleted `Codegen.TypeDiscovery` scoped by action kind, where upstream walks
each action's accepted attributes and follows relationships to their
destinations. Since stage 4b nothing here discovers types: a consumer takes
them from `Reachability` through the manifest, so the rest of #21 closed with
the deletion. Two measurements, and they say different things:

- Over this repo's fixtures, the deleted module and `manifest.types` found the
  same 7 embedded resources, 0 different in either direction (2026-09-17, at
  `5dc9e85`). Here the manifest is exactly as wide as what it replaced.
- In `ash_kotlin_multiplatform` PR #86, the consumer's old one-level attribute
  walk found 1 embedded resource over its fixtures and the manifest found 8.
  Against that walk the manifest is wider, and correctly so.

What remains: nothing here can compare the two any more, so a type the
manifest omits is an upstream gap and is found only in the consumer. PR #86
found one — an embedded resource reached only through a `first` aggregate —
and pins it with a test.

`Reachability` does **not** walk `load` statements, whatever an earlier version
of this page said. `grep load
deps/ash/lib/ash/info/manifest/generator/reachability.ex` returns two
`Code.ensure_loaded?/1` calls and nothing else (ash 3.33.1, checked
2026-09-10). The accepted-attribute walk is real —
`traverse_action_accepted_attributes/6` at line 208 — and so is the
relationship traversal at line 116. Do not size #23's port against a
capability upstream does not have.

### T2 — One consumer, no contract test

**The risk.** `ash_kotlin_multiplatform` depends on `ash_introspection ~> 0.4`
(`mix.exs:111`, checked 2026-09-17) and names `AshIntrospection` on 49 lines
across 22 files of its `lib/` (grep at its `70671e8`). Nothing in either repo
fails when the shared surface changes shape. The requirement admits every
0.4.x, so the consumer takes each such release here without review. It
excludes 0.5.0, which deletes `Codegen.TypeDiscovery`: that one needs a
deliberate bump in a consumer pull request.

**Why it bites.** The 0.3.0 rename of `code` to `type` is exactly the class of
change a contract test catches and a version constraint does not. It shipped
with a codemod (`mix ash_introspection.upgrade`), which limits the damage to
Elixir call sites; a generated Kotlin client that reads `error.code` is
regenerated, not migrated, and nothing checks that it was.

**Now realised, not hypothetical.** #44 found the consumer's Swift generator
sending `identity` on read actions — `generate_get_function/3` at
`lib/ash_kotlin_multiplatform/swift/codegen.ex:581-594` emits `identity: id`
for every `get?` read. This library dropped that parameter without a word, so
those calls have been returning the wrong record all along. They now fail with
`identity_not_supported`, which is the right answer and still a break the
consumer has to act on. Its Kotlin generator was never affected: it gates on
the same empty `identities` list upstream does.

**What we watch.** `grep -rn 'AshIntrospection' lib/` in the consumer, and the
consumer's `mix.exs` requirement, on every release here.

**What we would do.** Bump the consumer in the same session as a breaking
release here and run its suite, until there is a published contract test that
exercises the shared surface from the consumer's side. That test does not exist
yet and is not on the board.

**One half of it now does exist, for one surface.** #23 stage 1 added
`test/ash_introspection/resource_info_test.exs` and
`test/ash_introspection/rpc/pipeline_manifest_parity_test.exs`, and stage 2
added `test/ash_introspection/manifest/differential_test.exs`. Together they
run live introspection and a decorated manifest against each other field by
field, action by action, response by response. Stage 4a added a fourth for
codegen, 423 byte-for-byte comparisons, and stage 4b deleted it with the
module it compared. That is the differential test this page said was missing
— for `AshIntrospection.ResourceInfo`, and for nothing else. It says nothing
about whether the consumer's call sites still compile. The consumer's own copy
of the traversal is gone too (its PR #83), and its codegen reads
`manifest.types` (its PR #86).

Stage 2 is what those tests were for, and they earned it on the first run: they
found `relationship/3` answering `nil` for a private `belongs_to`, a bug stage
1 shipped and stage 1's own differential test could not see, because it walked
`public_relationships/1` only. A differential test is only as wide as the list
it iterates.

### T3 — The RPC layer is young code with new tests

**The risk.** `lib/ash_introspection/rpc/` had **zero** test coverage until the
week of 2026-09-09 (#18). Coverage arrived as regression tests attached to the
seven fixes shipped in 0.3.0 — one test per fixed bug, not a suite that
describes the pipeline. `mix test` on the #23 stage 2 branch reports 463 tests
and 1 doctest (2026-09-11), and whole modules (`value_formatter.ex`,
`field_extractor.ex`, `atomizer.ex`) are still exercised only incidentally.

**Why it bites.** #66, the one correctness bug still open, touches code that
has no behavioural test around it, so a fix can break a neighbour silently.
`lib/ash_introspection/rpc/errors.ex` is the shape to copy instead: #12 and #40
each landed with a test file for the failure they fixed, and
`errors_protocol_failure_test.exs` covers a raise, a throw and an exit out of an
`Error` protocol implementation in 7 tests.

**A test that asserts the shape and not the values is worse than none.** #62
was silent data loss — an untyped-map response reached the client with every
value replaced by `nil` — and the one existing test on that action passed
throughout, because it asked for an empty field list and so took a different
branch. Coverage counted; the payload did not. Assert the values a caller
receives, not the key casing and not the presence of keys.

**What we watch.** `mix test` count and which modules new tests land in. CI
runs the suite on every pull request as of #32.

**What we would do.** Keep landing a regression test with each fix, per #18's
own preference, and treat a fix that arrives without one as unfinished.

**The suite no longer flakes, and that is new.** Until #55, `mix test` failed
about 1 run in 40 on an unchanged `main` because five test files tore down a
VM-wide ETS table from `on_exit`. A flaky gate teaches reviewers to re-run
rather than read, which costs more than the flake.
`AshIntrospection.Test.Account` is now `private? true`, so isolation is a
property of the data layer. The replacement risk is smaller and stated here so
it is not rediscovered: a private ETS table belongs to the process that created
it, so a test that writes `Account` from a `Task` or a `setup_all` block will
read an empty table instead of failing loudly. Keep writes in the test process.

### T4 — Two stage-4 exits, and the consumer uses the untyped one

**The risk.** `Rpc.Pipeline` exposes two stage-4 functions.
`format_output_with_request/3` has the `%Request{}`, so it formats each value
by its declared type; `format_output/2` has no request and falls back to
`FieldFormatter.format_output_field_names/2`, which rewrites every key it can
reach. The type-driven guarantees #20 landed — a typed map's nested keys
camelized, a pinned interop name kept, an unconstrained `:map` passed through
verbatim — hold on the first function only.

**Why it bites.** `ash_kotlin_multiplatform` calls the second one.
`AshKotlinMultiplatform.Rpc.Runner.run_action/4` ends with
`Pipeline.format_output(processed)`
(`lib/ash_kotlin_multiplatform/rpc/runner.ex:157`), so the consumer's
successful responses never see the typed path. Its clients
still get `_id` rewritten to `id` inside an unconstrained map. The library is
correct and the deployed behaviour is not, which is the worst shape a fix can
take: a green suite here and no change downstream.

**What we watch.** `grep -rn 'Pipeline.format_output' lib/` in the consumer.
Measured 2026-09-09: the only live call is the untyped `format_output/1` in
`Runner`; the consumer's own `format_output/2` wraps
`format_output_with_request/3` and appears nowhere but its moduledoc example.
Any new wrapper is checked against the "Action metadata" section of
`Rpc.Pipeline`'s `@moduledoc` before it ships.

**What we would do.** Move the consumer to `format_output_with_request/3`; it
already builds the `%Request{}` two lines earlier, so the change is one line
plus its tests. That is a ticket in `ash_kotlin_multiplatform`, not here.
Collapsing the two functions into one is the larger answer and needs the
error-response path, which legitimately has no request, to keep working.

### T5 — Load restrictions read as a security control

**The risk.** `allowed_loads` / `denied_loads` (#19) shape which relationships,
calculations and aggregates a client may ask an action for. They look exactly
like an access-control list, and the next person to need "hide this field from
this caller" will reach for them. They are not that. Ash policies, field
policies and tenancy are what decide who may see a value, and they apply to
every load that passes a restriction.

**Why it bites.** A field denied on one action stays readable through every
other action and through any caller that is not this pipeline — a codegen
consumer, a LiveView, a script. Someone who believes the deny list is the
boundary ships a resource with no policy on it and no error to tell them.

**What we watch.** Every mention of load restrictions in a moduledoc, a doc
page or an error message says what they are for, which is cost: keeping an
expensive load off an endpoint that has no need for it. The moduledoc on
`AshIntrospection.Rpc.LoadRestrictions` says it first and says it plainly.
Upstream `ash_typescript` draws the same line in `24266dc`.

**What we would do.** If a consumer is found using a deny list where a policy
belongs, the fix is the policy; the restriction stays as the surface control it
is. If the confusion recurs, rename the config key to something that cannot be
read as authorization.

### T6 — Decoration that does not happen says nothing

**The risk.** `AshIntrospection.Manifest.Decorator` skips a module it cannot
load. `Code.ensure_loaded?/1` guards every read it makes, per the repo-wide
rule from #49, and a module that is not compiled yet when `decorate/3` runs
leaves its resource in the manifest bare. `AshIntrospection.ResourceInfo` then
reads that resource live — the right answer, computed the slow way, with no
warning and no log line. The same silence covers a namespace mismatch: a source
prepared under one `custom` key and read under another falls back the same way.

**Why it bites.** The failure mode is a performance regression that looks like
correct behaviour, which is the hardest kind to notice and the easiest to ship.
A resource missing from the decoration is also a resource whose precomputed
client names are missing, so a consumer that came to rely on
`formatted_field_names` gets the formatter's answer instead — identical
today, and only identical while nothing overrides it.

**What we watch.** `AshIntrospection.Manifest.Custom.decorated?/2` is the
question, and the tests ask it: `decorator_test.exs` asserts every resource,
every relationship and every entrypoint in the fixture manifest is decorated,
and `differential_test.exs` fails loudly if a fixture resource reaches it bare.
Neither can watch a consumer's manifest.

**What we would do.** Stage 3 owns the fix and must not skip it. Upstream's
`8c07331` is the shape: force every referenced module to compile before
decorating, and give the manifest module a compile-time dependency on the
domains it was built from, so an incremental compile of a resource recompiles
the manifest. A pure function of its arguments cannot own a dependency graph,
which is why `decorate/3` does not try. If stage 3 lands without those edges,
the right answer here is a `decorated?/2` assertion in the consumer's own test
suite rather than a warning from this library, which cannot tell a skipped
module from one nobody decorates.

## Operational

### O1 — Security drift in the dependency floor

**The risk.** A library's version floor is what its consumers inherit. Before
#28, `mix.exs` asked for `{:ash, ">= 3.7.0"}` with `mix.lock` pinned to 3.11.3,
which carried 13 known CVEs — three of them the same vulnerability classes
this repo had just fixed at its own layer. It went unnoticed until CI ran
`mix hex.audit` for the first time on PR #42.

**Why it bites.** The audit only exists because #32 added CI a week ago. Two
weeks of security work happened on top of a dependency that was vulnerable to
the same things.

**What we watch.** CI runs `mix hex.audit` and `mix deps.audit` on every pull
request, and Dependabot opens dependency bumps. Both are enforcing, not
advisory: the checks fail the build.

**What we would do.** Raise the floor rather than only the lock, as #28 did.
The floor is the consumer-visible number; bumping the lock alone protects this
repo's CI and nobody else.

## Product

### P1 — Alpha surface with a published Hex package

**The risk.** The README and `AshIntrospection`'s `@moduledoc` both say the API
may change without notice, and 0.3.0 duly removed a public function
(`FieldFormatter.convert_to_field_atom/2`) and renamed a payload key. The
package is on Hex, so anyone can depend on it without reading either warning.

**Why it bites.** The alpha label is not a substitute for a migration path. A
consumer that upgrades and finds `error.code` gone has no way to know that the
answer is `error.type`.

**What we watch.** Hex download counts against the one consumer we know about,
and any issue filed by someone outside `udin-io`.

**What we would do.** Keep shipping a codemod with every breaking release —
`mix ash_introspection.upgrade` exists for this, and the CHANGELOG names both
what it rewrites and what it can only print. Drop the alpha warning only when
the surface stops moving, not before.

## Keeping this page current

A change that creates a risk adds it here in the same pull request. A change
that retires one strikes it, rather than leaving it to read as live. Each entry
keeps its four parts: the risk, why it bites, what we watch, what we would do.
