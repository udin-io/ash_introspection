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
does it live at roughly 66 call sites (#23).

**Why it bites.** A bug fixed upstream stays live here, and it stays live in
`ash_kotlin_multiplatform`, which is what a real user runs.

**What we watch.** Upstream's changelog and commit range against the
extraction point. Issue #23 names the port set commit by commit. The backlog
items #19 through #26 are all upstream-parity work.

**What we would do.** Land #23 first so the introspection layers match, then
port the rest against the manifest instead of against live introspection.
Re-porting each fix onto live introspection is the expensive path and it is the
one we are on until #23 lands.

### T2 — One consumer, no contract test

**The risk.** `ash_kotlin_multiplatform` depends on `ash_introspection ~> 0.2.0`
and calls it at 35 sites across 21 files (measured 2026-09-09). Nothing in
either repo fails when the shared surface changes shape. The `~> 0.2.0`
requirement does not even admit the current 0.3.0, so the consumer is pinned
behind a release that changed the error payload.

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

### T3 — The RPC layer is young code with new tests

**The risk.** `lib/ash_introspection/rpc/` had **zero** test coverage until the
week of 2026-09-09 (#18). Coverage arrived as regression tests attached to the
seven fixes shipped in 0.3.0 — one test per fixed bug, not a suite that
describes the pipeline. `main` is at 281 tests, and whole modules
(`value_formatter.ex`, `field_extractor.ex`, `atomizer.ex`) are still exercised
only incidentally.

**Why it bites.** Every open correctness issue on the board (#35, #40, #16)
touches code that has no behavioural test around it, so a fix can break a
neighbour silently.

**What we watch.** `mix test` count and which modules new tests land in. CI
runs the suite on every pull request as of #32.

**What we would do.** Keep landing a regression test with each fix, per #18's
own preference, and treat a fix that arrives without one as unfinished.

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
