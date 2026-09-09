# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
