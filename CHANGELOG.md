# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
