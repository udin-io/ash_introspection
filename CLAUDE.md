<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# CLAUDE.md

Working rules that are true of **this** repo and nowhere else. Created for
issue #36, which found that every session was rediscovering the same conditions
from the code — three of them in one week. Read this before touching anything;
it is the file that saves you the debugging, not the file that describes the
library. For what the library is and where it is going, start at
[`docs/PROJECT.md`](docs/PROJECT.md).

## Project source of truth

`docs/` is this project's source of truth and it is committed, never
gitignored. [`docs/PROJECT.md`](docs/PROJECT.md) is the hub;
[`architecture.md`](docs/architecture.md),
[`roadmap.md`](docs/roadmap.md), [`risks.md`](docs/risks.md) and
[`decisions.md`](docs/decisions.md) each answer one question.

**Keep them current with every change.** A pull request that changes
behaviour, structure, a risk or a decision updates the affected pages in the
same pull request. A merge is not finished until the pages describe `main` as
it now is:

- New module, new dependency edge, or a change to who calls what → redraw
  [`docs/architecture.md`](docs/architecture.md).
- Issue closed → move it from "Next" to "Shipped" in
  [`docs/roadmap.md`](docs/roadmap.md), with its number and commit SHA. Closed
  without shipping → "Decided against", with the reason.
- Risk created or retired → add it to or strike it from
  [`docs/risks.md`](docs/risks.md).
- A choice a future reader would question → a dated entry in
  [`docs/decisions.md`](docs/decisions.md), including what it cost.

**No ADRs.** There is no `adr/` directory here and none should be created.
`docs/decisions.md` carries the decisions that still shape the code; git
carries the history.

## Project-specific lessons

One heading per lesson, each with the symptom and the reason. Add to this list
whenever you learn something a future session would otherwise rediscover the
hard way, and commit it with the work that taught it.

### `Igniter.update_all_elixir_files/2` reaches no file under `Igniter.Test`

**Symptom.** A codemod test is green and asserts nothing. The task runs, the
test passes, and zero files were processed.

**Why.** `Igniter.update_all_elixir_files/2` leans on `Igniter.include_glob/2`,
which in test mode only resolves an **absolute** glob (igniter 0.8.4,
`deps/igniter/lib/igniter.ex:266`), while `Igniter.update_glob/3` hands it a
relative one. Nothing errors — the file set is simply empty, so every
assertion about a rewrite passes vacuously.

**What we do.** `lib/mix/tasks/ash_introspection.upgrade.ex` includes the files
first with `Igniter.include_glob(igniter, Path.expand(glob))` before calling
`update_all_elixir_files/2`. See the comment at
`lib/mix/tasks/ash_introspection.upgrade.ex:105`. If you write another codemod,
copy that shape and assert that the rewrite happened, not just that the task
returned.

### `mix format` with `--stdin-filename` and no file argument formats everything

**Symptom.** You format one file and `git diff --stat` shows a dozen unrelated
files rewritten.

**Why.** `mix format --stdin-filename <path> < file` does **not** format stdin
when it is given no file argument. It blanket-formats the whole `inputs` glob
from `.formatter.exs`. In #12 that rewrote 13 unrelated files; it was caught
only by `git diff --stat`, reverted with `git checkout -- .`, and re-applied by
hand.

**What we do.** Always pass explicit file paths: `mix format path/to/file.ex`.

Historical note worth keeping: `main` used to be formatter-dirty because
`.formatter.exs` lacked `import_deps`, so any format churned unrelated regions
of files it touched and several pull requests that week had to hand-revert.
Fixed in #30 by adding `import_deps: [:ash, :spark]`, and CI now enforces
`mix format --check-formatted`. The blast radius is small now; the rule about
explicit paths still holds.

### Guard `function_exported?/3` with `Code.ensure_loaded?/1`

**Symptom.** A consumer-supplied callback is ignored, and the behaviour differs
between a warm and a cold VM. A test only reaches the branch after calling
`Code.ensure_loaded!/1` itself — that is the tell.

**Why.** Elixir loads modules lazily. `function_exported?/3` returns `false`
for a module the VM has not loaded yet, so a consumer's domain or type that has
not been touched in the current process silently takes the fallback path.

**What we do.** Every check against a module we did not write is guarded.
`lib/ash_introspection/type_system/introspection.ex` does it correctly at lines
276, 352, 464, 507 and 537. Issue #49 tracks one site that does not
(`Errors.get_show_raised_errors?/2`); grep for bare `function_exported?/3`
before adding another.

### No stdlib `JSON`: `mix.exs` declares `elixir: "~> 1.15"`

**Symptom.** Code using the `JSON` module compiles on your machine and fails on
a supported Elixir version.

**Why.** The stdlib `JSON` module only exists from Elixir 1.18, and this
library supports 1.15. Caught in review on PR #41.

**What we do.** Use `Jason`. `ash` depends on it non-optionally, so it is
always available and does not need to be a direct dependency. See the note at
`test/ash_introspection/rpc/errors_json_safety_test.exs:27`.

### No database — ETS only

**Symptom.** None; this is here so you do not create one.

**Why.** This library never persists anything. `test/support/*.ex` declares
`data_layer: Ash.DataLayer.Ets` on every test resource. There is no repo, no
`priv/repo/migrations`, no `priv/resource_snapshots` and no seeds.

**What we do.** `mix deps.get && mix test` is the whole setup. Ignore the
partition-database workflow: no `DEV_DB_PARTITION`, no `MIX_TEST_PARTITION`, no
`mix ash.setup`, no `mix ash.codegen`, no `mix ash.tear_down`. A worktree here
needs `deps/` and `_build/` copied in and nothing else.

### Protocol consolidation is off in `:test` on purpose

**Symptom.** You "clean up" `consolidate_protocols: Mix.env() != :test` in
`mix.exs` and `test/ash_introspection/rpc/error_type_key_test.exs` starts
failing.

**Why.** Tests define their own `defimpl AshIntrospection.Rpc.Error` for
throwaway structs (see that file, line 15) to exercise the fallback paths.
Consolidation freezes the protocol's implementation list at compile time, so a
test-defined implementation would never be found.

### This library ships no `config/`, deliberately

**Symptom.** You add a setting to `config/config.exs` and expect consumers to
get it. They do not.

**Why.** `mix.exs` keeps `config` out of the published `files` list. The
settings in `config/config.exs` apply only to the test resources compiled here.
`config :ash, default_string_length_count: :codepoints` is there because `ash`
3.33.0 refuses to compile a resource until the host application states how
string length is counted (CVE-2026-82752) — that is the consumer's choice to
make, not ours.

`config/test.exs` sets `config :ash, :validate_domain_config_inclusion?, false`
because `test/support/*.ex` defines throwaway Ash domains that are deliberately
not registered under `ash_domains`. Without it, Ash's compile-time check fails
`mix compile --warnings-as-errors` in CI. See #39.

### Every source file carries a REUSE/SPDX header

**Symptom.** A new file looks fine and is inconsistent with all 49 others.

**Why.** The repo follows REUSE: `LICENSES/MIT.txt` plus a two-line SPDX header
at the top of every `.ex`, `.exs` and `.md` file. Markdown uses an HTML comment.

**What we do.** Copy the header from a neighbouring file when you create one:

```elixir
# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT
```

### The consumer is not covered by anything here

**Symptom.** A change passes 255 tests here and breaks
`ash_kotlin_multiplatform`.

**Why.** `ash_kotlin_multiplatform` calls `AshIntrospection` at 35 sites across
21 files (measured 2026-09-09) and there is no contract test between the two
repos. Its `mix.exs` still asks for `~> 0.2.0`, which does not admit 0.3.0.

**What we do.** Before changing a public function on `Rpc.Pipeline`,
`Rpc.Request`, `FieldFormatter`, `Helpers`, `TypeSystem.Introspection` or
`Codegen.ActionIntrospection`, grep the consumer at
`~/work/clients/udin/ash/ash_kotlin_multiplatform`. A breaking change ships a
codemod step in `mix ash_introspection.upgrade` and a CHANGELOG entry naming
what the codemod cannot reach.

## CI and the definition of green

`.github/workflows/ci.yml` runs on every push to `main` and every pull request,
on OTP 27 / Elixir 1.18.4, and all five steps are enforcing:

```
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix hex.audit
mix deps.audit
```

`main` is at **255 tests, 0 failures**. A pull request that changes that number
downward, or that leaves a compiler warning, is not finished. Never suppress a
warning — fix the cause.

## Markdown in this repo

Prose in every `.md` file hard-wraps at 80 characters. Table rows, fenced code
blocks and links may exceed it; nothing else may. Check before committing:

```
awk 'length > 80' <file>
```

Every document opens with one paragraph of context under the title, before any
heading, written for someone opening the file cold from a link.
