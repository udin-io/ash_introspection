# SPDX-FileCopyrightText: 2025 ash_introspection contributors <https://github.com/ash-project/ash_introspection/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Codegen.ValidationErrorTypes do
  @moduledoc """
  Provides language-agnostic classification of validation error types for Ash types.

  This module uses a unified type-driven dispatch pattern for classifying Ash types
  into their corresponding validation error type categories. Language-specific
  generators (TypeScript, Kotlin, etc.) can use this classification to generate
  appropriate error type definitions.

  ## Error Type Categories

  The module classifies types into the following error categories:

  - `:primitive_errors` - Simple string error messages (for strings, integers, etc.)
  - `:array_errors` - Array of inner error type
  - `:resource_errors` - Validation errors for an Ash resource
  - `:typed_container_errors` - Errors for a map/struct with field constraints
  - `:union_errors` - Errors for union type members
  - `:custom_type_errors` - Errors for custom types with interop_type_name callback
  - `:unconstrained_map_errors` - Generic record/map errors

  ## Usage

  ```elixir
  # Classify a type
  {:ok, classification} = classify_error_type(Ash.Type.String, [])
  # => {:ok, {:primitive_errors, nil}}

  # Classify an embedded resource
  {:ok, classification} = classify_error_type(Ash.Type.Struct, [instance_of: MyEmbeddedResource])
  # => {:ok, {:resource_errors, MyEmbeddedResource}}

  # Classify an array of resources
  {:ok, classification} = classify_error_type({:array, Ash.Type.Struct}, [items: [instance_of: MyResource]])
  # => {:ok, {:array_errors, {:resource_errors, MyResource}}}
  ```
  """

  alias AshIntrospection.TypeSystem.Introspection

  # ─────────────────────────────────────────────────────────────────
  # Core Type Classification
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Classifies an Ash type into its corresponding validation error type category.

  This is the unified dispatcher that handles all type-to-error-type classifications.
  NewTypes are unwrapped at entry for consistent handling.

  ## Parameters
  - `type` - The Ash type (atom, tuple, or module)
  - `constraints` - Type constraints (keyword list)

  ## Returns
  `{:ok, classification}` where classification is one of:
  - `{:primitive_errors, nil}` - Simple string errors
  - `{:array_errors, inner_classification}` - Array with inner error type
  - `{:resource_errors, resource_module}` - Resource validation errors
  - `{:typed_container_errors, field_classifications}` - Container with field errors
  - `{:union_errors, member_classifications}` - Union member errors
  - `{:custom_type_errors, type_module}` - Custom type with interop_type_name
  - `{:unconstrained_map_errors, nil}` - Generic map errors
  """
  @spec classify_error_type(atom() | tuple(), keyword()) ::
          {:ok,
           {:primitive_errors, nil}
           | {:array_errors, term()}
           | {:resource_errors, module()}
           | {:typed_container_errors, list()}
           | {:union_errors, list()}
           | {:custom_type_errors, module()}
           | {:unconstrained_map_errors, nil}}
  def classify_error_type(type, constraints \\ [])

  # Handle nil type
  def classify_error_type(nil, _constraints), do: {:ok, {:primitive_errors, nil}}

  def classify_error_type(type, constraints) do
    # Unwrap NewTypes FIRST (consistent with ValueFormatter pattern)
    {unwrapped_type, full_constraints} = Introspection.unwrap_new_type(type, constraints)

    classification =
      cond do
        # Arrays - recurse into inner type
        match?({:array, _}, type) ->
          {:array, inner_type} = type
          inner_constraints = Keyword.get(constraints, :items, [])
          {:ok, inner_classification} = classify_error_type(inner_type, inner_constraints)
          {:array_errors, inner_classification}

        # Custom types with interop_type_name (check before embedded resource)
        Introspection.is_custom_interop_type?(unwrapped_type) ->
          {:custom_type_errors, unwrapped_type}

        # Embedded resources
        Introspection.is_embedded_resource?(unwrapped_type) ->
          {:resource_errors, unwrapped_type}

        # Union types
        unwrapped_type == Ash.Type.Union ->
          union_types = Introspection.get_union_types_from_constraints(unwrapped_type, full_constraints)
          member_classifications = classify_union_members(union_types)
          {:union_errors, member_classifications}

        # Typed containers (Map, Keyword, Tuple) with potential field constraints
        unwrapped_type in [Ash.Type.Map, Ash.Type.Keyword, Ash.Type.Tuple] ->
          classify_typed_container(full_constraints)

        # Ash.Type.Struct - check for instance_of
        unwrapped_type == Ash.Type.Struct ->
          classify_struct_type(full_constraints)

        # Types with fields and instance_of (TypedStruct pattern via NewType)
        Keyword.has_key?(full_constraints, :fields) and
            Keyword.has_key?(full_constraints, :instance_of) ->
          instance_of = Keyword.get(full_constraints, :instance_of)
          {:resource_errors, instance_of}

        # Enum types - just primitive errors
        Spark.implements_behaviour?(unwrapped_type, Ash.Type.Enum) ->
          {:primitive_errors, nil}

        # All primitives and unknown types
        true ->
          {:primitive_errors, nil}
      end

    {:ok, classification}
  end

  # ─────────────────────────────────────────────────────────────────
  # Type-Specific Classifiers
  # ─────────────────────────────────────────────────────────────────

  defp classify_struct_type(constraints) do
    instance_of = Keyword.get(constraints, :instance_of)

    cond do
      # instance_of pointing to embedded resource
      instance_of && Introspection.is_embedded_resource?(instance_of) ->
        {:resource_errors, instance_of}

      # instance_of pointing to module with interop_type_name
      instance_of && Introspection.is_custom_interop_type?(instance_of) ->
        {:custom_type_errors, instance_of}

      # Has fields constraint - typed container
      Keyword.has_key?(constraints, :fields) ->
        classify_typed_container(constraints)

      # Fallback - unconstrained map
      true ->
        {:unconstrained_map_errors, nil}
    end
  end

  defp classify_typed_container(constraints) do
    fields = Keyword.get(constraints, :fields, [])

    if fields == [] do
      {:unconstrained_map_errors, nil}
    else
      field_classifications =
        Enum.map(fields, fn {field_name, field_config} ->
          field_type = Keyword.get(field_config, :type)
          field_constraints = Keyword.get(field_config, :constraints, [])
          {:ok, field_classification} = classify_error_type(field_type, field_constraints)

          {field_name, field_classification}
        end)

      {:typed_container_errors, field_classifications}
    end
  end

  defp classify_union_members(union_types) do
    Enum.map(union_types, fn {type_name, type_config} ->
      member_type = Keyword.get(type_config, :type)
      member_constraints = Keyword.get(type_config, :constraints, [])
      {:ok, member_classification} = classify_error_type(member_type, member_constraints)

      {type_name, member_classification}
    end)
  end

  # ─────────────────────────────────────────────────────────────────
  # Action Error Type Analysis
  # ─────────────────────────────────────────────────────────────────

  @doc """
  Returns the list of input fields for an action with their error type classifications.

  This is useful for generating validation error types for action inputs.

  ## Parameters
  - `resource` - The Ash resource module
  - `action` - The action struct

  ## Returns
  A list of `{field_name, classification, field_struct}` tuples, or empty list if no inputs.
  """
  def classify_action_input_errors(resource, action) do
    # Get public arguments
    public_arguments = Enum.filter(action.arguments, & &1.public?)

    # Get accepted attributes (for create/update/destroy actions)
    accepted_attributes =
      (Map.get(action, :accept) || [])
      |> Enum.map(&Ash.Resource.Info.attribute(resource, &1))
      |> Enum.reject(&is_nil/1)

    inputs = public_arguments ++ accepted_attributes

    Enum.map(inputs, fn input ->
      {:ok, classification} = classify_error_type(input.type, input.constraints || [])
      {input.name, classification, input}
    end)
  end

  @doc """
  Returns error type classifications for all public attributes of a resource.

  This is useful for generating validation error types for embedded resources.

  ## Parameters
  - `resource` - The Ash resource module

  ## Returns
  A list of `{field_name, classification, attribute_struct}` tuples.
  """
  def classify_resource_attribute_errors(resource) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Enum.map(fn attr ->
      {:ok, classification} = classify_error_type(attr.type, attr.constraints || [])
      {attr.name, classification, attr}
    end)
  end

  @doc """
  Returns error type classifications for fields in a typed struct/container.

  ## Parameters
  - `fields` - Keyword list of field definitions from type constraints

  ## Returns
  A list of `{field_name, classification}` tuples.
  """
  def classify_field_errors(fields) when is_list(fields) do
    Enum.map(fields, fn {field_name, field_config} ->
      field_type = Keyword.get(field_config, :type)
      field_constraints = Keyword.get(field_config, :constraints, [])
      {:ok, classification} = classify_error_type(field_type, field_constraints)

      {field_name, classification}
    end)
  end
end
