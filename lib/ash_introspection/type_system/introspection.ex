# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.TypeSystem.Introspection do
  @moduledoc """
  Core type introspection and classification for Ash types.

  This module provides a centralized set of functions for determining the nature
  and characteristics of Ash types, including embedded resources, typed structs,
  unions, and primitive types.

  Used throughout the codebase for type checking, code generation, and runtime
  processing.
  """

  @doc """
  Checks if a module is an embedded Ash resource.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.is_embedded_resource?(MyApp.Accounts.Address)
      true

      iex> AshIntrospection.TypeSystem.Introspection.is_embedded_resource?(MyApp.Accounts.User)
      false
  """
  def is_embedded_resource?(module) when is_atom(module) do
    Ash.Resource.Info.resource?(module) and Ash.Resource.Info.embedded?(module)
  end

  def is_embedded_resource?(_), do: false

  @doc """
  Checks if a type is a primitive Ash type (not a complex or composite type).

  Primitive types include basic types like String, Integer, Boolean, Date, UUID, etc.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.is_primitive_type?(Ash.Type.String)
      true

      iex> AshIntrospection.TypeSystem.Introspection.is_primitive_type?(Ash.Type.Union)
      false
  """
  def is_primitive_type?(type) do
    type in [
      Ash.Type.Integer,
      Ash.Type.String,
      Ash.Type.Boolean,
      Ash.Type.Float,
      Ash.Type.Decimal,
      Ash.Type.Date,
      Ash.Type.DateTime,
      Ash.Type.NaiveDatetime,
      Ash.Type.UtcDatetime,
      Ash.Type.Atom,
      Ash.Type.UUID,
      Ash.Type.Binary
    ]
  end

  @doc """
  Classifies an Ash type into a category for processing purposes.

  Returns one of:
  - `:union_attribute` - Union type
  - `:embedded_resource` - Single embedded resource
  - `:embedded_resource_array` - Array of embedded resources
  - `:tuple` - Tuple type
  - `:attribute` - Simple attribute (default)

  ## Parameters
  - `type_module` - The Ash type module (e.g., Ash.Type.String, Ash.Type.Union)
  - `attribute` - The attribute struct containing type and constraints
  - `is_array` - Whether this is inside an array type

  ## Examples

      iex> attr = %{type: MyApp.Address, constraints: []}
      iex> AshIntrospection.TypeSystem.Introspection.classify_ash_type(MyApp.Address, attr, false)
      :embedded_resource
  """
  def classify_ash_type(type_module, _attribute, is_array) do
    cond do
      type_module == Ash.Type.Union ->
        :union_attribute

      is_embedded_resource?(type_module) ->
        if is_array, do: :embedded_resource_array, else: :embedded_resource

      type_module == Ash.Type.Tuple ->
        :tuple

      true ->
        :attribute
    end
  end

  @doc """
  Extracts union types from an attribute's constraints.

  Handles both direct union types and array union types.

  ## Examples

      iex> attr = %{type: Ash.Type.Union, constraints: [types: [note: [...], url: [...]]]}
      iex> AshIntrospection.TypeSystem.Introspection.get_union_types(attr)
      [note: [...], url: [...]]
  """
  def get_union_types(attribute) do
    get_union_types_from_constraints(attribute.type, attribute.constraints)
  end

  @doc """
  Extracts union types from type and constraints directly.

  Useful when you have constraints but not the full attribute struct.
  Handles both direct union types and array union types.

  ## Examples

      iex> constraints = [types: [note: [...], url: [...]]]
      iex> AshIntrospection.TypeSystem.Introspection.get_union_types_from_constraints(Ash.Type.Union, constraints)
      [note: [...], url: [...]]
  """
  def get_union_types_from_constraints(type, constraints) do
    case type do
      Ash.Type.Union ->
        Keyword.get(constraints, :types, [])

      {:array, Ash.Type.Union} ->
        items_constraints = Keyword.get(constraints, :items, [])
        Keyword.get(items_constraints, :types, [])

      _ ->
        []
    end
  end

  @doc """
  Extracts the inner type from an array type.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.get_inner_type({:array, Ash.Type.String})
      Ash.Type.String

      iex> AshIntrospection.TypeSystem.Introspection.get_inner_type(Ash.Type.String)
      Ash.Type.String
  """
  def get_inner_type({:array, inner_type}), do: inner_type
  def get_inner_type(type), do: type

  @doc """
  Checks if a type is an Ash type module.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.is_ash_type?(Ash.Type.String)
      true

      iex> AshIntrospection.TypeSystem.Introspection.is_ash_type?(MyApp.CustomType)
      true

      iex> AshIntrospection.TypeSystem.Introspection.is_ash_type?(:string)
      false
  """
  def is_ash_type?(module) when is_atom(module) do
    Ash.Type.ash_type?(module)
  rescue
    _ -> false
  end

  def is_ash_type?(_), do: false

  @doc """
  Recursively unwraps Ash.Type.NewType to get the underlying type and constraints.

  When a type is wrapped in one or more NewType wrappers, this function
  recursively unwraps them until it reaches the base type. If the NewType
  has a callback for field names and the constraints don't already
  have an `instance_of` key, it will add the NewType module as `instance_of`
  to preserve the reference for field name mapping.

  ## Parameters
  - `type` - The type to unwrap (e.g., MyApp.CustomType)
  - `constraints` - The constraints for the type
  - `field_names_callback` - The callback name to check for field name mappings (default: :interop_field_names)

  ## Returns
  A tuple `{unwrapped_type, unwrapped_constraints}` where:
  - `unwrapped_type` is the final underlying type after all NewType unwrapping
  - `unwrapped_constraints` are the final constraints, potentially augmented with `instance_of`

  ## Examples

      iex> # Simple NewType with field_names callback
      iex> unwrap_new_type(MyApp.TaskStats, [], :interop_field_names)
      {Ash.Type.Struct, [fields: [...], instance_of: MyApp.TaskStats]}

      iex> # Non-NewType (returns unchanged)
      iex> unwrap_new_type(Ash.Type.String, [max_length: 50], :interop_field_names)
      {Ash.Type.String, [max_length: 50]}
  """
  def unwrap_new_type(type, constraints, field_names_callback \\ :interop_field_names)

  def unwrap_new_type(type, constraints, field_names_callback) when is_atom(type) do
    if Ash.Type.NewType.new_type?(type) do
      subtype = Ash.Type.NewType.subtype_of(type)

      # Get constraints from the NewType
      # Ash.Type.NewType.constraints/2 only returns passed constraints when lazy_init? is false,
      # but do_init/1 returns the full merged constraints including subtype_constraints
      constraints =
        case type.do_init(constraints) do
          {:ok, merged_constraints} -> merged_constraints
          {:error, _} -> constraints
        end

      # Preserve reference to outermost NewType with field_names callback
      # Only add instance_of if:
      # 1. This NewType has the field_names callback (check based on callback type)
      # 2. Constraints don't already have instance_of (preserves outermost)
      has_callback = check_field_names_callback(type, field_names_callback)

      augmented_constraints =
        if has_callback and not Keyword.has_key?(constraints, :instance_of) do
          Keyword.put(constraints, :instance_of, type)
        else
          constraints
        end

      {subtype, augmented_constraints}
    else
      {type, constraints}
    end
  end

  def unwrap_new_type(type, constraints, _field_names_callback), do: {type, constraints}

  # Check if a type has the field names callback
  # Supports both atom callback names and function references
  defp check_field_names_callback(type, callback) when is_atom(callback) do
    function_exported?(type, callback, 0)
  end

  defp check_field_names_callback(type, callback) when is_function(callback, 1) do
    callback.(type)
  end

  defp check_field_names_callback(_type, _callback), do: false

  # ---------------------------------------------------------------------------
  # Interop Field Names Helpers (Generalized)
  # ---------------------------------------------------------------------------

  @doc """
  Checks if a module has an interop_field_names/0 callback.

  This is the generalized callback that works with all language generators
  (TypeScript, Kotlin, etc.).

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.has_interop_field_names?(MyApp.TaskStats)
      true

      iex> AshIntrospection.TypeSystem.Introspection.has_interop_field_names?(Ash.Type.String)
      false
  """
  def has_interop_field_names?(nil), do: false

  def has_interop_field_names?(module) when is_atom(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :interop_field_names, 0)
  end

  def has_interop_field_names?(_), do: false

  @doc """
  Gets the interop_field_names as a map, or empty map if not available.

  This is the generalized version that works with all language generators.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.get_interop_field_names_map(MyApp.TaskStats)
      %{is_active?: "isActive", meta_1: "meta1"}

      iex> AshIntrospection.TypeSystem.Introspection.get_interop_field_names_map(Ash.Type.String)
      %{}
  """
  def get_interop_field_names_map(nil), do: %{}

  def get_interop_field_names_map(module) when is_atom(module) do
    if has_interop_field_names?(module) do
      module.interop_field_names() |> Map.new()
    else
      %{}
    end
  end

  def get_interop_field_names_map(_), do: %{}

  @doc """
  Builds a reverse mapping from client names to internal names.

  Can take either a map of field names or a module with interop_field_names/0.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.build_reverse_field_names_map(%{is_active?: "isActive"})
      %{"isActive" => :is_active?}

      iex> AshIntrospection.TypeSystem.Introspection.build_reverse_field_names_map(MyApp.TaskStats)
      %{"isActive" => :is_active?, "meta1" => :meta_1}
  """
  def build_reverse_field_names_map(field_names) when is_map(field_names) do
    field_names
    |> Enum.map(fn {internal, client} -> {client, internal} end)
    |> Map.new()
  end

  def build_reverse_field_names_map(module) when is_atom(module) do
    module
    |> get_interop_field_names_map()
    |> build_reverse_field_names_map()
  end

  def build_reverse_field_names_map(_), do: %{}

  # ---------------------------------------------------------------------------
  # Custom Interop Type Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Checks if a type is a custom Ash type with an interop_type_name callback.

  Custom types are Ash types that define an `interop_type_name/0` callback
  to specify their representation in generated code.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.is_custom_interop_type?(MyApp.MyCustomType)
      true

      iex> AshIntrospection.TypeSystem.Introspection.is_custom_interop_type?(Ash.Type.String)
      false
  """
  def is_custom_interop_type?(type) when is_atom(type) and not is_nil(type) do
    Code.ensure_loaded?(type) and
      function_exported?(type, :interop_type_name, 0) and
      Spark.implements_behaviour?(type, Ash.Type)
  end

  def is_custom_interop_type?(_), do: false

  @doc """
  Gets the interop type name for a custom type, or nil if not available.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.get_interop_type_name(MyApp.MyCustomType)
      "MyCustomType"

      iex> AshIntrospection.TypeSystem.Introspection.get_interop_type_name(Ash.Type.String)
      nil
  """
  def get_interop_type_name(type) when is_atom(type) and not is_nil(type) do
    if is_custom_interop_type?(type) do
      type.interop_type_name()
    else
      nil
    end
  end

  def get_interop_type_name(_), do: nil

  # ---------------------------------------------------------------------------
  # Type Constraint Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Checks if constraints specify an instance_of that is an Ash resource.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.is_resource_instance_of?([instance_of: MyApp.Todo])
      true

      iex> AshIntrospection.TypeSystem.Introspection.is_resource_instance_of?([])
      false
  """
  def is_resource_instance_of?(constraints) when is_list(constraints) do
    case Keyword.get(constraints, :instance_of) do
      nil -> false
      module -> is_atom(module) && Ash.Resource.Info.resource?(module)
    end
  end

  def is_resource_instance_of?(_), do: false

  @doc """
  Checks if constraints include non-empty field definitions.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.has_field_constraints?([fields: [name: [type: :string]]])
      true

      iex> AshIntrospection.TypeSystem.Introspection.has_field_constraints?([fields: []])
      false
  """
  def has_field_constraints?(constraints) when is_list(constraints) do
    Keyword.has_key?(constraints, :fields) && Keyword.get(constraints, :fields) != []
  end

  def has_field_constraints?(_), do: false

  @doc """
  Gets the type and constraints for a field from field specs.

  ## Examples

      iex> specs = [name: [type: :string], age: [type: :integer]]
      iex> AshIntrospection.TypeSystem.Introspection.get_field_spec_type(specs, :name)
      {:string, []}

      iex> AshIntrospection.TypeSystem.Introspection.get_field_spec_type(specs, :unknown)
      {nil, []}
  """
  def get_field_spec_type(field_specs, field_name) when is_list(field_specs) do
    case Enum.find(field_specs, fn {name, _spec} -> name == field_name end) do
      nil -> {nil, []}
      {_name, spec} -> {Keyword.get(spec, :type), Keyword.get(spec, :constraints, [])}
    end
  end

  def get_field_spec_type(_, _), do: {nil, []}

  # ---------------------------------------------------------------------------
  # TypeScript-Specific Helpers (For Backward Compatibility)
  # ---------------------------------------------------------------------------

  @doc """
  Checks if a module has a typescript_field_names/0 callback.

  This is TypeScript-specific but included here for compatibility with
  modules that use the TypeScript-specific callback instead of the
  generalized interop_field_names callback.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.has_typescript_field_names?(MyApp.TaskStats)
      true

      iex> AshIntrospection.TypeSystem.Introspection.has_typescript_field_names?(Ash.Type.String)
      false
  """
  def has_typescript_field_names?(nil), do: false

  def has_typescript_field_names?(module) when is_atom(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :typescript_field_names, 0)
  end

  def has_typescript_field_names?(_), do: false

  @doc """
  Gets the typescript_field_names as a map, or empty map if not available.

  Falls back to interop_field_names if typescript_field_names is not available.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.get_typescript_field_names_map(MyApp.TaskStats)
      %{is_active?: "isActive", meta_1: "meta1"}
  """
  def get_typescript_field_names_map(nil), do: %{}

  def get_typescript_field_names_map(module) when is_atom(module) do
    cond do
      has_typescript_field_names?(module) ->
        module.typescript_field_names() |> Map.new()

      has_interop_field_names?(module) ->
        get_interop_field_names_map(module)

      true ->
        %{}
    end
  end

  def get_typescript_field_names_map(_), do: %{}

  @doc """
  Checks if a type is a custom Ash type with a typescript_type_name callback.

  This is TypeScript-specific but included for compatibility.

  ## Examples

      iex> AshIntrospection.TypeSystem.Introspection.is_custom_typescript_type?(MyApp.MyCustomType)
      true
  """
  def is_custom_typescript_type?(type) when is_atom(type) and not is_nil(type) do
    Code.ensure_loaded?(type) and
      function_exported?(type, :typescript_type_name, 0) and
      Spark.implements_behaviour?(type, Ash.Type)
  end

  def is_custom_typescript_type?(_), do: false

  # ---------------------------------------------------------------------------
  # Field Names Callback Detection (Generic)
  # ---------------------------------------------------------------------------

  @doc """
  Checks if a module has a field names callback of the specified type.

  ## Parameters
  - `module` - The module to check
  - `callback` - Either an atom callback name (e.g., :interop_field_names) or
                 a function `(module -> boolean)` for custom detection

  ## Examples

      iex> has_field_names_callback?(MyApp.TaskStats, :interop_field_names)
      true

      iex> has_field_names_callback?(MyApp.TaskStats, :typescript_field_names)
      true
  """
  def has_field_names_callback?(nil, _callback), do: false

  def has_field_names_callback?(module, callback) when is_atom(module) and is_atom(callback) do
    Code.ensure_loaded?(module) && function_exported?(module, callback, 0)
  end

  def has_field_names_callback?(module, callback) when is_atom(module) and is_function(callback, 1) do
    callback.(module)
  end

  def has_field_names_callback?(_, _), do: false

  @doc """
  Gets field names map using the specified callback, with fallback to interop_field_names.

  ## Parameters
  - `module` - The module to get field names from
  - `callback` - The callback name to use (e.g., :typescript_field_names)

  ## Examples

      iex> get_field_names_map(MyApp.TaskStats, :typescript_field_names)
      %{is_active?: "isActive", meta_1: "meta1"}
  """
  def get_field_names_map(nil, _callback), do: %{}

  def get_field_names_map(module, callback) when is_atom(module) and is_atom(callback) do
    cond do
      function_exported?(module, callback, 0) ->
        apply(module, callback, []) |> Map.new()

      has_interop_field_names?(module) ->
        get_interop_field_names_map(module)

      true ->
        %{}
    end
  end

  def get_field_names_map(_, _), do: %{}
end
