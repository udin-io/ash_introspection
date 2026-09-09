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

**What we do.** Every check against a module we did not write is guarded. #49
swept the library and guarded ten sites across `Rpc.Errors`,
`Rpc.ResultProcessor`, `Rpc.FieldProcessing.Atomizer`,
`Rpc.FieldProcessing.FieldSelector`, `Rpc.Pipeline`, `TypeSystem.Introspection`
and `Codegen.TypeDiscovery`. Grep for bare `function_exported?/3` before adding
another; `grep -rn 'function_exported?' lib | grep -v 'Code.ensure_loaded?'`
should print only comment and continuation lines of guarded expressions.

**Not every guarded site is observable.** `get_field_mapping_module/3` in
`Rpc.Pipeline` is the one that has no test. Both of its outcomes — the
consumer's struct module, or `nil` — reach
`ResultProcessor.get_field_type_info/3`, which answers `{nil, []}` either way,
so the whole suite passes with the branch hard-coded to `nil` (measured
2026-09-09, 281 tests). The guard is still right; do not delete it because
nothing covers it, and do not write a test that cannot fail.

**Testing it.** A test that calls `Code.ensure_loaded!/1` to reach the branch
proves nothing — it loads the module and hides the bug. Unload the module
first (`:code.purge/1`, `:code.delete/1`, `:code.purge/1`), assert
`refute :erlang.module_loaded(module)`, then call the public function. The
module must be defined in `test/support/*.ex` and not inline in the `.exs`:
only a module with a `.beam` file on disk can be loaded back. Unloading is
global to the VM, so such a file is `async: false`. See
`test/ash_introspection/lazy_module_loading_test.exs`.

### A casing assertion cannot see double formatting

**Symptom.** You suspect a value is being formatted twice, write a test that
asserts the final key casing, and it passes against both the buggy and the
fixed code.

**Why.** `FieldFormatter.format_field_name/2` is idempotent for ordinary
names: `changed_by` camelizes to `changedBy`, and `changedBy` is already
camelCase so a second pass returns it unchanged. The same holds for digits and
leading underscores — `_id` and `field_1_name` both settle after one pass
(measured 2026-09-09 across `_id`, `_type`, `_created_at`, `field_1_name`,
`meta_1`, `a__b`, `id_`, `http_url`, `v2_token`). So a double-formatting bug is
invisible to a casing assertion.

**What we do.** Reach for a name the formatter cannot derive. A NewType with
`interop_field_names/0` pins its client names, and a pinned name that is not
camelCase changes under a second pass: `AshIntrospection.Test.RevisionInfo`
maps `:revision` to `_rev`, which a second camelization rewrites to `rev`. See
`test/ash_introspection/rpc/pipeline_metadata_formatting_test.exs`.

### Never call `Ash.DataLayer.Ets.stop/1` in a test — fixed in #55

**Symptom, before the fix.** Roughly one `mix test` run in forty failed on
`main` with no source change, always in a file that writes
`AshIntrospection.Test.Account`. The message was either `record with id: "..."
not found` or the real one:

```
** (ArgumentError) errors were found at the given arguments:
  * 1st argument: the table identifier does not refer to an existing ETS table
```

**Why.** Five test files called `Ash.DataLayer.Ets.stop(Account)` from
`on_exit`. Without `private?`, the Ets data layer keeps one named table per
resource for the whole VM, owned by a `TableManager` GenServer, and `stop/1`
only sends it `Process.exit(pid, :shutdown)` before returning
(`deps/ash/lib/ash/data_layer/ets/ets.ex:180`). The kill is asynchronous, so
the next test's `setup` could reach `TableManager.start/3`, wrap the table the
VM had not yet reaped, and write to a dead reference. The race is **inside one
file**, between one test's `on_exit` and the next test's `setup` — not across
files, and `async: false` does not prevent it.

**The measurement.** Both figures are 200 consecutive runs on this machine, at
`f43a4ea`: the full suite failed 5 times before the fix and 0 after, and
`pipeline_filter_injection_test.exs` run alone failed 11 times before and 0
after. `--seed` does not pin it: seed `850929` failed once in 30 runs of that
file, the same rate as any other seed. It is a timing race, so a failing seed
is not a repro — a loop is.

**What we do.** `test/support/rpc_resources.ex` declares `ets do private?(true)
end` on `Account`, so every test process gets its own unnamed table that the VM
reaps when the process exits. There is nothing to tear down: **do not add an
`Ash.DataLayer.Ets.stop/1` call anywhere.** The one thing a private table
forbids is writing the resource from another process — a `Task`, a spawned
process, or a `setup_all` block sees an empty table, because the table lives in
the creating process's dictionary. Keep writes in the test process. If a new
test resource needs writing, give it `private? true` at birth.

### A new load in `FieldSelector` needs a `check_load_allowed!/3`

**Symptom.** A load restriction that works for every other field is silently
ignored for the one you just added, and no test fails.

**Why.** `AshIntrospection.Rpc.LoadRestrictions` is enforced at the six points
where `Rpc.FieldProcessing.FieldSelector` appends to the Ash load statement,
not by walking the finished load statement. That is deliberate — a separate
traversal has to re-derive which parts of a load list are loads and which are
selects, and upstream's did it wrong (`ash_typescript` `3aaae6b`). The price is
that a seventh append site added later is unguarded by default and nothing says
so.

**What we do.** Check that every hit of this grep has a
`check_load_allowed!(path, internal_name, config)` above it:

```
grep -n 'load ++ \|load_acc ++' \
  lib/ash_introspection/rpc/field_processing/field_selector.ex
```

#24 (relationship query envelopes) adds one: a relationship loaded through an
`%Ash.Query{}` envelope.

**Two of the six cannot be made to refuse.** The embedded-attribute and
union-member sites only fire when a nested selection already produced a load,
and that nested load passed the check one level deeper; a passing child implies
a passing parent under both `:allow` and `:deny`. Do not write a test that
claims otherwise, and do not delete the guards — see the comments at those
sites. See `test/ash_introspection/rpc/load_restrictions_test.exs`.

**They are not authorization.** Ash policies apply to every load that gets
through. Say so in anything you write about them; risk T5 in
[`docs/risks.md`](docs/risks.md) explains why it matters.
### An upstream fix that hangs off a Spark extension cannot be ported here

**Symptom.** You start porting an `ash_typescript` commit, reach for
`AshIntrospection.Resource`, and there is no such module. Nothing errors — you
are about to invent an extension to hold the port.

**Why.** This library ships no DSL of its own. `grep 'use Spark.Dsl.Extension'
lib` returns nothing, and the only extension in the tree is the test-only
`AshIntrospection.Test.RpcDsl` (see its moduledoc). Upstream hangs transformers
and verifiers off `AshTypescript.Resource`; the equivalent configuration here
lives in the **consumer** and arrives as callbacks in the pipeline config
map — `:format_field_for_client`, `:get_original_field_name`,
`:field_names_callback`.
The core reads a consumer's DSL only through
`Spark.Dsl.Extension.fetch_opt/3` on a section it does not name, in
`Rpc.Errors`.

**What we do.** When an upstream commit's mechanism is a transformer or a
verifier, stop and check what it reads before porting. If it reads a DSL
section, the port is not a port: either the consumer wires it up in its own
extension, or it waits for #23. Do not add a resource extension to this library
to hold one — that is #23's decision, not a ticket's. #26 was closed this way;
[`docs/decisions.md`](docs/decisions.md) has the reasoning and the numbers.

### Field-name formatting is ~2% of the pipeline; the cost is the regexes

**Symptom.** An upstream performance commit quotes a large call count, and you
are about to cache something here on the strength of it.

**Why.** Upstream's figures are upstream's. Measured here at `0dd9ac5` on OTP
27 and Elixir 1.18.4, over 100 single-record RPC runs through
`execute_ash_action/1`, `process_result/3` and `format_output_with_request/3`:
`FieldFormatter.format_field_name/2` is called **6 times per record** — the
selected field names plus the `"success"` and `"data"` envelope literals — at
~470 ns each. That is under 1 ms against 32-42 ms of `execute_ash_action/1`.
Ash action execution is 95% of the pipeline.

Within that 470 ns, `Macro.camelize/1` — the work that transforms the name —
is ~60 ns. The rest is `is_camel_case?/1`, `is_pascal_case?/1` and
`is_snake_case?/1`, which each run one or two `String.match?/2` calls at ~295 ns
apiece. A binary-walk clause computing the same answer measures ~10 ns.

**What we do.** Measure before optimising this function, and optimise the
predicates rather than caching the result. A cache helps resource fields only;
the predicates are on every caller's path, codegen and errors included.

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

**Symptom.** A change passes 281 tests here and breaks
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

`main` is at **309 tests, 0 failures**. A pull request that changes that number
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
