# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- Client-supplied field names no longer mint atoms
  ([#10](https://github.com/udin-io/ash_introspection/issues/10)). The atom
  table is never garbage collected, so a request carrying unknown field names
  grew it without bound and could take the node down. Field selection now
  resolves names against atoms that already exist and rejects the rest as
  unknown fields.

### Added

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
