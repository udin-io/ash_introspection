<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# Architecture

C4 views of `ash_introspection` as it stands on `main`, 0.4.0 plus the
unreleased work through issue #23 stage 2, drawn from the code rather than from
the README. It exists because issue #36 found no written
account of the one relationship that confuses every new reader: `ash_typescript`
is upstream and standalone, this library is the core extracted from it, and
`ash_kotlin_multiplatform` is the only thing that depends on it. Use these
diagrams to decide where a change belongs before writing it.

## 1. Context

Who and what this library talks to. Solid arrows are compile-time or runtime
dependencies; the dashed arrow is provenance, not a dependency.

```mermaid
flowchart TB
    dev["Ash application developer<br/>writes resources, runs codegen"]
    app["Host Elixir application<br/>Ash domains and resources"]
    kclient["Kotlin/Swift client<br/>generated data classes and RPC calls"]
    ash["Ash framework 3.33+<br/>resources, types, queries, changesets"]

    akm["ash_kotlin_multiplatform<br/>udin-io &middot; only consumer"]
    ai["ash_introspection<br/>udin-io &middot; THIS LIBRARY"]
    ats["ash_typescript 0.18<br/>ash-project &middot; upstream, standalone"]

    dev -->|"writes resources in"| app
    dev -->|"runs mix codegen task"| akm
    app -->|"declares domains and RPC actions for"| akm
    akm -->|"hex dep: ash_introspection ~> 0.3"| ai
    akm -->|"emits source files"| kclient
    kclient -->|"RPC request over HTTP"| app
    ai -->|"introspects at compile and run time"| ash
    app -->|"built on"| ash
    ats -.->|"source of the extraction; no dependency either way"| ai
```

`ash_typescript` never calls this library and this library never calls it. The
shared code was copied out, so the two drift independently — see
[risks.md](risks.md).

## 2. Container

The publishable and runtime units. `ash_introspection` has no processes of its
own: it is compiled into the consumer, which is compiled into the host
application.

```mermaid
flowchart TB
    subgraph host["Host Elixir application (BEAM)"]
        domains["Ash domains and resources"]
        plug["HTTP endpoint / Phoenix router<br/>routes RPC requests"]
        akm["ash_kotlin_multiplatform<br/>Rpc.Pipeline, Rpc.Runner, Codegen"]
        ai["ash_introspection<br/>shared pipeline + introspection"]
        ashlib["ash ~> 3.33, spark ~> 2.6"]
    end

    subgraph build["Build time only"]
        codegen["mix ash_kotlin.codegen"]
        upgrade["mix ash_introspection.upgrade<br/>Igniter codemod, dev/test dep"]
    end

    subgraph out["Generated client (outside the BEAM)"]
        kmp["Kotlin Multiplatform / Swift sources"]
    end

    plug --> akm
    akm --> ai
    ai --> ashlib
    domains --> ashlib
    codegen --> akm
    codegen --> kmp
    upgrade -->|"rewrites consumer source on version bump"| akm
    kmp -->|"HTTP"| plug
```

The `igniter` dependency is `only: [:dev, :test]`, and
`lib/mix/tasks/ash_introspection.upgrade.ex` guards itself with
`Code.ensure_loaded?(Igniter)`, so a production consumer never loads it.

## 3. Component — what the consumer actually calls

Only part of this library is consumer-facing. Everything else is reached
through `Rpc.Pipeline`. Stage 1 of the pipeline (parsing a client request) is
deliberately absent here: it is language-specific and lives in the consumer.

```mermaid
flowchart LR
    subgraph consumer["ash_kotlin_multiplatform"]
        cpipe["Rpc.Pipeline<br/>stage 1: parse_request/3"]
        crun["Rpc.Runner"]
        ccodegen["Codegen.TypeMapper<br/>Codegen.ResourceSchemas<br/>Rpc.Codegen"]
    end

    subgraph public["ash_introspection: called from outside"]
        pipeline["Rpc.Pipeline<br/>execute_ash_action/2<br/>process_result/3<br/>format_output/2<br/>format_output_with_request/3<br/>format_sort_string/2"]
        request["Rpc.Request<br/>the struct crossing all four stages"]
        ff["FieldFormatter"]
        helpers["Helpers<br/>snake_to_camel_case, snake_to_pascal_case"]
        tsi["TypeSystem.Introspection"]
        actint["Codegen.ActionIntrospection"]
    end

    subgraph internal["ash_introspection: reached through the pipeline"]
        fsel["Rpc.FieldProcessing.FieldSelector"]
        lrest["Rpc.LoadRestrictions"]
        atomz["Rpc.FieldProcessing.Atomizer"]
        fval["Rpc.FieldProcessing.Validation"]
        rproc["Rpc.ResultProcessor"]
        vfmt["Rpc.ValueFormatter"]
        fext["Rpc.FieldExtractor"]
        errs["Rpc.Errors"]
        errb["Rpc.ErrorBuilder"]
        errp["Rpc.Error (protocol)"]
        errh["Rpc.DefaultErrorHandler"]
        efmt["ErrorFormatter"]
        rinfo["ResourceInfo<br/>the only caller of Ash.Resource.Info"]
        rfields["TypeSystem.ResourceFields"]
        tdisc["Codegen.TypeDiscovery"]
        vet["Codegen.ValidationErrorTypes"]
        mcustom["Manifest.Custom ((NEW))<br/>the only reader of custom"]
    end

    subgraph compile["ash_introspection: compile time only"]
        mdec["Manifest.Decorator ((NEW))<br/>decorate/3, the only writer of custom"]
    end

    ash["Ash: Ash.read, Ash.create,<br/>Ash.Resource.Info, Ash.Info.Manifest"]

    cpipe -->|"%Request{}"| pipeline
    cpipe --> request
    cpipe --> fsel
    crun --> pipeline
    ccodegen --> tsi
    ccodegen --> actint
    ccodegen --> helpers
    ccodegen --> ff

    pipeline --> rproc
    pipeline --> vfmt
    pipeline --> ff
    pipeline --> efmt
    pipeline --> tsi
    pipeline --> ash
    fsel -->|"one load path per append"| lrest
    fsel --> atomz
    fsel --> fval
    fsel --> rfields
    fsel --> tsi
    rproc --> fext
    rproc --> vfmt
    errs --> errp
    errs --> errb
    errs --> errh
    errs --> efmt
    tdisc --> tsi
    vet --> tsi
    actint --> vet
    actint --> tsi

    pipeline --> rinfo
    fsel --> rinfo
    rproc --> rinfo
    vfmt --> rinfo
    rfields --> rinfo
    tsi --> rinfo
    actint --> rinfo
    vet --> rinfo
    tdisc --> rinfo
    rinfo -->|"live, or an Ash.Info.Manifest<br/>off the config map's :manifest key"| ash
    rinfo -->|"decorated reads"| mcustom
    actint -->|"return classification"| mcustom
    mdec -->|"writes custom.namespace"| mcustom
    mdec -->|"asks once, at compile time"| rinfo
    ccodegen -.->|"stage 3: calls decorate/3 from a transformer"| mdec
```

`ResourceInfo` is the seam issue #23 stage 1 added. Every `Ash.Resource.Info`
call in `lib/` goes through it — 64 of them, measured at `74afafd` — so a
later stage changes one module rather than nine. With no `:manifest` key on the
config map it reads live introspection, which is what every caller does today.
`grep -rn 'Ash\.Resource\.Info\.' lib` should match nothing outside
`lib/ash_introspection/resource_info.ex` and
`lib/ash_introspection/manifest/decorator.ex`.

`Manifest.Decorator` and `Manifest.Custom` are what #23 stage 2 added. The
dashed arrow is the edge that does not exist yet: nothing in this repo calls
`decorate/3` outside `test/support/manifest_fixture.ex`, and until stage 3
builds a manifest in the consumer, every production read is still live.

Measured 2026-09-09: `ash_kotlin_multiplatform` names `AshIntrospection` at 35
call sites across 21 files. `Helpers` is the most used (10), then
`TypeSystem.Introspection` (5), `FieldFormatter` (4), `Rpc.Request` (3),
`Rpc.Pipeline` (2) and `Codegen.ActionIntrospection` (2). That distribution is
why a change to `Helpers` or `TypeSystem.Introspection` is a breaking change in
practice even when the version number says otherwise.

## 4. The compile-time decoration pass

The second flow worth reading in order. It runs once, when the consumer's
manifest module compiles, and everything it writes is read by the request path
without touching `Ash.Resource.Info` again. The consumer half is stage 3 of
issue #23 and does not exist yet, which is why the first two messages are
dashed.

```mermaid
sequenceDiagram
    participant T as Consumer manifest transformer
    participant G as Ash.Info.Manifest.Generator
    participant D as AshIntrospection.Manifest.Decorator
    participant R as AshIntrospection.ResourceInfo
    participant I as Ash.Resource.Info
    participant P as Request path

    Note over T: stage 3, not built yet
    T-->>G: generate(otp_app, action_entrypoints)
    G-->>T: %Ash.Info.Manifest{}
    T->>D: decorate(manifest, namespace, config)
    D->>D: prepare the undecorated source, for declared_resource?/2
    loop each resource in the manifest
        D->>I: attributes, calculations, aggregates, actions, aggregate_type
        I-->>D: the live structs
        D->>D: format field and argument names per built-in formatter
        D->>D: classify each action's return type
        loop each relationship on it
            D->>R: relationship_pagination/3, relationship_read_action/3
            R->>I: relationship, primary_action, action
            I-->>R: the read behind it
            R-->>D: :offset | :keyset | :mixed | :none, and the action name
        end
    end
    D->>D: build the entrypoint lookup, raising on a duplicate client name
    D-->>T: the manifest with custom.namespace populated
    Note over T: persisted in the consumer's Spark DSL state
    T-->>P: config map carrying :manifest
    P->>R: attribute, action, aggregate_type, relationship_pagination, ...
    R-->>P: read out of custom.namespace, no Ash.Resource.Info call
```

A module the decorator cannot load is **skipped**, not guessed at:
`Code.ensure_loaded?/1` guards every read, per the repo-wide rule from #49, and
the resource stays in the manifest bare. A bare resource reads live, so the
answer is right and nothing says the decoration was missed. That silence is the
staleness trap #23 records: the caller owns the compile edges — forcing every
referenced module to compile first, and giving the manifest module a
compile-time dependency on the domains it was built from — and that is stage
3's job, not this library's.

## 5. The four-stage RPC pipeline

The one flow worth reading in order, because each stage constrains the next and
only three of the four live here.

```mermaid
sequenceDiagram
    participant C as Kotlin client
    participant P as Host endpoint
    participant K as AshKotlinMultiplatform.Rpc.Pipeline
    participant S as AshIntrospection.Rpc.Pipeline
    participant F as Rpc.FieldProcessing.FieldSelector
    participant A as Ash
    participant E as Rpc.Errors

    C->>P: POST rpc action, fields, input, filter, sort
    P->>K: params, actor, tenant
    Note over K: Stage 1 is language-specific<br/>and lives in the consumer
    K->>F: process(fields, resource, action, config)
    Note over F: each append to the load statement<br/>passes Rpc.LoadRestrictions.check!/2<br/>when config carries :load_restrictions
    F-->>K: {select, load, extraction_template}
    K->>S: execute_ash_action(%Request{}, config)
    S->>A: Ash.read / create / update / destroy / run_action
    alt action succeeds
        A-->>S: records or Ash.Page
        S-->>K: {:ok, result}
        K->>S: process_result(result, request, config)
        Note over S: applies the extraction template<br/>and redacts ForbiddenField / NotLoaded
        S-->>K: {:ok, filtered}
        K->>S: format_output_with_request(filtered, request, config)
        Note over S: camelizes keys, formats values by type
        S-->>K: %{success: true, data: ...}
    else action fails
        A-->>S: {:error, Ash error}
        S-->>K: {:error, error}
        K->>E: to_errors(error, request, config)
        Note over E: classifies under `type`, strips policy<br/>breakdowns and exception text,<br/>keeps %{placeholders} matched to vars
        E-->>K: %{success: false, errors: [...]}
    end
    K-->>P: response map
    P-->>C: JSON
```

Two properties of the error branch are load-bearing and easy to undo: the class
of the error is reported under `type` and never `code` (0.3.0), and a
message's `%{placeholder}` names must keep matching the keys in `vars` after
Stage 4 has camelized everything around them. Both have regression tests —
`test/ash_introspection/rpc/error_type_key_test.exs` and
`test/ash_introspection/rpc/pipeline_error_placeholder_test.exs`.

## 6. What is not here

- **No manifest module, and no manifest in production yet.** Stage 1 of issue
  #23 added `AshIntrospection.ResourceInfo` and an optional `:manifest` config
  key; stage 2 added the decorator that fills it and the reader that empties
  it. Nothing builds a manifest: the manifest module needs a Spark DSL to
  declare entrypoints, and #23 puts that DSL in `ash_kotlin_multiplatform`, not
  here. So every read in production is still live, and stage 2's decoration is
  exercised only by `test/support/manifest_fixture.ex`. Stages 3 to 5 are on
  the roadmap — see [roadmap.md](roadmap.md) and
  [decisions.md](decisions.md).
- **No persistence.** `test/support/*.ex` uses `Ash.DataLayer.Ets`; there is no
  repo, no migration directory and no database setup step.
- **No contract test with the consumer.** Nothing in either repo fails when the
  shared surface changes shape. See [risks.md](risks.md).
