# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.FieldProcessing.Atomizer do
  @moduledoc """
  Handles preprocessing of requested fields, converting map keys to atoms
  while preserving field name strings for later reverse mapping lookup.

  Field name strings are preserved so that downstream processors can perform
  proper reverse mapping lookups using the original client field names.
  The actual conversion to atoms happens in the field processor after
  the correct internal field name has been resolved.

  This is a shared module used by both AshTypescript and AshKotlinMultiplatform.
  Language-specific behavior is configured via the config parameter.
  """

  @type config :: %{
          optional(:input_field_formatter) => atom(),
          optional(:resource_info_module) => module(),
          optional(:is_interop_resource?) => (module() -> boolean()),
          optional(:get_original_field_name) => (module(), String.t() -> atom() | nil)
        }

  @doc """
  Processes requested fields, converting map keys to atoms for navigation
  while preserving field name strings for reverse mapping.

  For resources with field_names DSL mappings, those are applied to convert
  client names to internal names. For other types (TypedStructs, NewTypes),
  strings are preserved for the field processor to handle.

  ## Parameters

  - `requested_fields` - List of strings/atoms or maps for relationships
  - `resource` - Optional resource module for field_names DSL lookup
  - `config` - Language-specific configuration with:
    - `:input_field_formatter` - The formatter for input field names (default: :camel_case)
    - `:resource_info_module` - Module implementing resource info callbacks (optional)
    - `:is_interop_resource?` - Function to check if resource is an interop resource
    - `:get_original_field_name` - Function to get original field name from client name

  ## Examples

      iex> atomize_requested_fields(["id", "title", %{"user" => ["id", "name"]}], nil, %{})
      [:id, :title, %{user: ["id", "name"]}]

      iex> atomize_requested_fields([%{"self" => %{"args" => %{"prefix" => "test"}}}], nil, %{})
      [%{self: %{args: %{prefix: "test"}}}]
  """
  @spec atomize_requested_fields(list(), module() | nil, config()) :: list()
  def atomize_requested_fields(requested_fields, resource \\ nil, config \\ %{})

  def atomize_requested_fields(requested_fields, resource, config) when is_list(requested_fields) do
    formatter = Map.get(config, :input_field_formatter, :camel_case)
    Enum.map(requested_fields, &process_field(&1, formatter, resource, config))
  end

  @doc """
  Processes a single field, which can be a string, atom, or map structure.

  For string field names:
  - If resource has a field_names mapping for this client name, returns the mapped atom
  - Otherwise, preserves the string for downstream reverse mapping lookup

  For map structures:
  - Converts map keys to atoms (for relationship/calculation navigation)
  - Preserves nested field name strings
  """
  @spec process_field(term(), atom(), module() | nil, config()) :: term()
  def process_field(field, formatter, resource \\ nil, config \\ %{})

  def process_field(field_name, _formatter, resource, config) when is_binary(field_name) do
    is_interop_resource? = Map.get(config, :is_interop_resource?)
    get_original_field_name = Map.get(config, :get_original_field_name)
    resource_info_module = Map.get(config, :resource_info_module)

    cond do
      # Use custom callback if provided
      is_interop_resource? && get_original_field_name && resource ->
        if is_interop_resource?.(resource) do
          case get_original_field_name.(resource, field_name) do
            original when is_atom(original) -> original
            _ -> field_name
          end
        else
          field_name
        end

      # Use resource info module if provided
      resource_info_module && resource ->
        is_resource? =
          if function_exported?(resource_info_module, :interop_resource?, 1) do
            apply(resource_info_module, :interop_resource?, [resource])
          else
            false
          end

        if is_resource? do
          case apply(resource_info_module, :get_original_field_name, [resource, field_name]) do
            original when is_atom(original) -> original
            _ -> field_name
          end
        else
          field_name
        end

      # Default: return as-is
      true ->
        field_name
    end
  end

  def process_field(field_name, _formatter, _resource, _config) when is_atom(field_name) do
    field_name
  end

  def process_field(%{} = field_map, formatter, resource, config) do
    is_calc_args = is_calculation_args_map?(field_map)

    Enum.into(field_map, %{}, fn {key, value} ->
      atom_key = convert_map_key_to_atom(key, formatter, resource, config)
      processed_value = process_field_value(value, formatter, resource, config, is_calc_args)
      {atom_key, processed_value}
    end)
  end

  def process_field(other, _formatter, _resource, _config) do
    other
  end

  defp convert_map_key_to_atom(key, _formatter, resource, config) when is_binary(key) do
    is_interop_resource? = Map.get(config, :is_interop_resource?)
    get_original_field_name = Map.get(config, :get_original_field_name)
    resource_info_module = Map.get(config, :resource_info_module)

    cond do
      # Use custom callback if provided
      is_interop_resource? && get_original_field_name && resource ->
        if is_interop_resource?.(resource) do
          case get_original_field_name.(resource, key) do
            original when is_atom(original) -> original
            _ -> key
          end
        else
          key
        end

      # Use resource info module if provided
      resource_info_module && resource ->
        is_resource? =
          if function_exported?(resource_info_module, :interop_resource?, 1) do
            apply(resource_info_module, :interop_resource?, [resource])
          else
            false
          end

        if is_resource? do
          case apply(resource_info_module, :get_original_field_name, [resource, key]) do
            original when is_atom(original) -> original
            _ -> key
          end
        else
          key
        end

      # Default: return as-is
      true ->
        key
    end
  end

  defp convert_map_key_to_atom(key, _formatter, _resource, _config) when is_atom(key) do
    key
  end

  defp is_calculation_args_map?(map) when is_map(map) do
    Map.has_key?(map, "args") or Map.has_key?(map, :args) or
      Map.has_key?(map, "fields") or Map.has_key?(map, :fields)
  end

  @doc """
  Processes field values, handling lists and nested maps.

  For calculation args (maps with args/fields keys), converts all strings.
  For field selection lists, preserves strings for type-aware reverse mapping.
  """
  @spec process_field_value(term(), atom(), module() | nil, config(), boolean()) :: term()
  def process_field_value(value, formatter, resource \\ nil, config \\ %{}, atomize_strings \\ true)

  def process_field_value(list, formatter, resource, config, atomize_strings) when is_list(list) do
    Enum.map(list, fn
      field_name when is_binary(field_name) ->
        if atomize_strings do
          process_field(field_name, formatter, resource, config)
        else
          field_name
        end

      %{} = map ->
        process_field(map, formatter, resource, config)

      other ->
        other
    end)
  end

  def process_field_value(%{} = map, formatter, resource, config, _atomize_strings) do
    process_field(map, formatter, resource, config)
  end

  def process_field_value(primitive, _formatter, _resource, _config, _atomize_strings) do
    primitive
  end

  # Legacy function names for backwards compatibility
  def atomize_field(field, formatter, resource, config),
    do: process_field(field, formatter, resource, config)

  def atomize_field_value(value, formatter, resource, config, atomize_strings),
    do: process_field_value(value, formatter, resource, config, atomize_strings)
end
