# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ValueFormatter do
  @moduledoc """
  Unified value formatting for RPC input/output.

  Traverses composite values recursively, applying field name mappings
  and type-aware formatting at each level.

  The type and constraints parameters provide all context needed - no separate
  "resource" context is required because each type is self-describing:
  - For Ash resources: field types come from `Ash.Resource.Info.attribute/2`
  - For TypedStructs: field types come from `constraints[:fields]`
  - For typed maps: field types come from `constraints[:fields]`
  - For unions: member type and constraints come from `constraints[:types][member]`

  ## Configuration

  This module uses a config map for language-specific customization:

  ```elixir
  %{
    input_field_formatter: :camel_case,
    output_field_formatter: :camel_case,
    field_names_callback: :interop_field_names,  # or :typescript_field_names
    get_original_field_name: fn resource, client_key -> ... end,
    format_field_for_client: fn field_name, resource, formatter -> ... end
  }
  ```

  ## Key Design Principle

  The "parent resource" is never needed because each type is self-describing.
  When we recurse into a nested value, we pass the field's type and constraints,
  which contain all the information needed to format that value correctly.
  """

  alias AshIntrospection.FieldFormatter
  alias AshIntrospection.TypeSystem.{Introspection, ResourceFields}

  @type direction :: :input | :output

  @type config :: %{
          optional(:input_field_formatter) => atom(),
          optional(:output_field_formatter) => atom(),
          optional(:field_names_callback) => atom(),
          optional(:get_original_field_name) => (module(), String.t() -> atom() | nil),
          optional(:format_field_for_client) => (atom(), module() | nil, atom() -> String.t())
        }

  @doc """
  Formats a value based on its type and constraints.

  ## Parameters
  - `value` - The value to format
  - `type` - The Ash type (e.g., `MyApp.EmbeddedResource`, `Ash.Type.Map`, `{:array, X}`)
  - `constraints` - Type constraints (e.g., `[fields: [...]]`, `[instance_of: Module]`)
  - `direction` - `:input` (client→internal) or `:output` (internal→client)
  - `config` - Configuration map with formatters and callbacks

  ## Returns
  The formatted value with field names converted according to direction.
  """
  @spec format(term(), atom() | tuple() | nil, keyword(), direction(), config()) :: term()
  def format(value, type, constraints, direction, config \\ %{})

  def format(nil, _type, _constraints, _direction, _config), do: nil
  def format(value, nil, _constraints, _direction, _config), do: value

  def format(value, type, constraints, direction, config) do
    field_names_callback = Map.get(config, :field_names_callback, :interop_field_names)
    {unwrapped_type, full_constraints} = Introspection.unwrap_new_type(type, constraints, field_names_callback)

    cond do
      match?({:array, _}, type) ->
        {:array, inner_type} = type
        inner_constraints = Keyword.get(constraints, :items, [])
        format_array(value, inner_type, inner_constraints, direction, config)

      is_atom(unwrapped_type) && Ash.Resource.Info.resource?(unwrapped_type) ->
        format_resource(value, unwrapped_type, direction, config)

      unwrapped_type == Ash.Type.Struct &&
          Introspection.is_resource_instance_of?(full_constraints) ->
        instance_of = Keyword.get(full_constraints, :instance_of)
        format_resource(value, instance_of, direction, config)

      unwrapped_type == Ash.Type.Tuple ->
        format_tuple(value, full_constraints, direction, config)

      unwrapped_type == Ash.Type.Keyword ->
        format_keyword(value, full_constraints, direction, config)

      has_field_names_callback?(full_constraints[:instance_of], field_names_callback) ->
        format_typed_struct(value, full_constraints, direction, config)

      unwrapped_type in [Ash.Type.Map, Ash.Type.Struct] &&
          Introspection.has_field_constraints?(full_constraints) ->
        format_typed_map(value, full_constraints, direction, config)

      unwrapped_type == Ash.Type.Union ->
        format_union(value, full_constraints, direction, config)

      is_custom_type_with_map_storage?(unwrapped_type) && is_map(value) && not is_struct(value) ->
        format_map_keys_only(value, direction, config)

      true ->
        value
    end
  end

  defp has_field_names_callback?(nil, _callback), do: false

  defp has_field_names_callback?(module, callback) when is_atom(module) and is_atom(callback) do
    Code.ensure_loaded?(module) && function_exported?(module, callback, 0)
  end

  defp has_field_names_callback?(_, _), do: false

  defp is_custom_type_with_map_storage?(module) when is_atom(module) do
    Ash.Type.ash_type?(module) and
      Ash.Type.storage_type(module) == :map and
      not Ash.Type.builtin?(module)
  rescue
    _ -> false
  end

  defp is_custom_type_with_map_storage?(_), do: false

  defp format_map_keys_only(map, :output, config) when is_map(map) do
    formatter = Map.get(config, :output_field_formatter, :camel_case)

    Enum.into(map, %{}, fn {key, value} ->
      string_key = FieldFormatter.format_field_name(key, formatter)

      formatted_value =
        case value do
          nested_map when is_map(nested_map) and not is_struct(nested_map) ->
            format_map_keys_only(nested_map, :output, config)

          list when is_list(list) ->
            Enum.map(list, fn item ->
              if is_map(item) and not is_struct(item) do
                format_map_keys_only(item, :output, config)
              else
                item
              end
            end)

          other ->
            other
        end

      {string_key, formatted_value}
    end)
  end

  defp format_map_keys_only(map, :input, config) when is_map(map) do
    formatter = Map.get(config, :input_field_formatter, :camel_case)

    Enum.into(map, %{}, fn {key, value} ->
      internal_key = FieldFormatter.parse_input_field(key, formatter)

      formatted_value =
        case value do
          nested_map when is_map(nested_map) and not is_struct(nested_map) ->
            format_map_keys_only(nested_map, :input, config)

          list when is_list(list) ->
            Enum.map(list, fn item ->
              if is_map(item) and not is_struct(item) do
                format_map_keys_only(item, :input, config)
              else
                item
              end
            end)

          other ->
            other
        end

      {internal_key, formatted_value}
    end)
  end

  defp format_map_keys_only(value, _direction, _config), do: value

  # ---------------------------------------------------------------------------
  # Resource Handler
  # ---------------------------------------------------------------------------

  defp format_resource(value, resource, direction, config)
       when is_map(value) and not is_struct(value) do
    formatter = get_formatter(direction, config)

    Enum.into(value, %{}, fn {key, field_value} ->
      internal_key = convert_resource_key(key, resource, direction, config)
      {field_type, field_constraints} = ResourceFields.get_field_type_info(resource, internal_key)
      formatted_value = format(field_value, field_type, field_constraints, direction, config)

      output_key =
        case direction do
          :input -> internal_key
          :output -> format_field_for_client(internal_key, resource, formatter, config)
        end

      {output_key, formatted_value}
    end)
  end

  defp format_resource(value, _resource, _direction, _config), do: value

  defp convert_resource_key(key, resource, :input, config) when is_binary(key) do
    # Try language-specific lookup first
    get_original = Map.get(config, :get_original_field_name)

    original =
      if is_function(get_original, 2) do
        get_original.(resource, key)
      else
        nil
      end

    case original do
      original when is_atom(original) ->
        original

      _ ->
        formatter = Map.get(config, :input_field_formatter, :camel_case)
        FieldFormatter.parse_input_field(key, formatter)
    end
  end

  defp convert_resource_key(key, _resource, :input, _config), do: key
  defp convert_resource_key(key, _resource, :output, _config), do: key

  # ---------------------------------------------------------------------------
  # TypedStruct Handler
  # ---------------------------------------------------------------------------

  defp format_typed_struct(value, constraints, direction, config) when is_map(value) do
    field_specs = Keyword.get(constraints, :fields, [])
    instance_of = Keyword.get(constraints, :instance_of)
    field_names_callback = Map.get(config, :field_names_callback, :interop_field_names)
    field_names_map = get_field_names_map(instance_of, field_names_callback)
    reverse_map = Introspection.build_reverse_field_names_map(field_names_map)

    Enum.into(value, %{}, fn {key, field_value} ->
      internal_key = convert_typed_struct_key(key, reverse_map, direction, config)

      {field_type, field_constraints} =
        Introspection.get_field_spec_type(field_specs, internal_key)

      formatted_value = format(field_value, field_type, field_constraints, direction, config)

      output_key =
        case direction do
          :input -> internal_key
          :output -> get_typed_struct_output_key(internal_key, field_names_map, config)
        end

      {output_key, formatted_value}
    end)
  end

  defp format_typed_struct(value, _constraints, _direction, _config), do: value

  defp get_field_names_map(nil, _callback), do: %{}

  defp get_field_names_map(module, callback) when is_atom(module) and is_atom(callback) do
    if Code.ensure_loaded?(module) && function_exported?(module, callback, 0) do
      apply(module, callback, []) |> Map.new()
    else
      %{}
    end
  end

  defp get_field_names_map(_, _), do: %{}

  defp convert_typed_struct_key(key, reverse_map, :input, config) when is_binary(key) do
    case Map.get(reverse_map, key) do
      nil ->
        formatter = Map.get(config, :input_field_formatter, :camel_case)
        FieldFormatter.parse_input_field(key, formatter)

      internal ->
        internal
    end
  end

  defp convert_typed_struct_key(key, _reverse_map, _direction, _config), do: key

  defp get_typed_struct_output_key(internal_key, field_names_map, config) do
    case Map.get(field_names_map, internal_key) do
      nil ->
        formatter = Map.get(config, :output_field_formatter, :camel_case)
        FieldFormatter.format_field_name(internal_key, formatter)

      client_name ->
        client_name
    end
  end

  # ---------------------------------------------------------------------------
  # Typed Map Handler
  # ---------------------------------------------------------------------------

  defp format_typed_map(value, constraints, direction, config) when is_map(value) do
    field_specs = Keyword.get(constraints, :fields, [])

    if field_specs == [] do
      value
    else
      formatter = get_formatter(direction, config)

      Enum.into(value, %{}, fn {key, field_value} ->
        internal_key =
          case direction do
            :input -> FieldFormatter.parse_input_field(key, formatter)
            :output -> key
          end

        {field_type, field_constraints} =
          Introspection.get_field_spec_type(field_specs, internal_key)

        formatted_value = format(field_value, field_type, field_constraints, direction, config)

        output_key =
          case direction do
            :input -> internal_key
            :output -> FieldFormatter.format_field_name(internal_key, formatter)
          end

        {output_key, formatted_value}
      end)
    end
  end

  defp format_typed_map(value, _constraints, _direction, _config), do: value

  # ---------------------------------------------------------------------------
  # Tuple Handler
  # ---------------------------------------------------------------------------

  defp format_tuple(value, constraints, direction, config) when is_tuple(value) do
    field_specs = Keyword.get(constraints, :fields, [])
    instance_of = Keyword.get(constraints, :instance_of)
    field_names_callback = Map.get(config, :field_names_callback, :interop_field_names)

    map_value =
      field_specs
      |> Enum.with_index()
      |> Enum.into(%{}, fn {{field_name, _field_spec}, index} ->
        {field_name, elem(value, index)}
      end)

    if has_field_names_callback?(instance_of, field_names_callback) do
      format_typed_struct(map_value, constraints, direction, config)
    else
      format_typed_map(map_value, constraints, direction, config)
    end
  end

  defp format_tuple(value, constraints, direction, config) when is_map(value) do
    instance_of = Keyword.get(constraints, :instance_of)
    field_names_callback = Map.get(config, :field_names_callback, :interop_field_names)

    if has_field_names_callback?(instance_of, field_names_callback) do
      format_typed_struct(value, constraints, direction, config)
    else
      format_typed_map(value, constraints, direction, config)
    end
  end

  defp format_tuple(value, _constraints, _direction, _config), do: value

  # ---------------------------------------------------------------------------
  # Keyword Handler
  # ---------------------------------------------------------------------------

  defp format_keyword(value, constraints, direction, config) when is_list(value) do
    instance_of = Keyword.get(constraints, :instance_of)
    map_value = Enum.into(value, %{})
    field_names_callback = Map.get(config, :field_names_callback, :interop_field_names)

    if has_field_names_callback?(instance_of, field_names_callback) do
      format_typed_struct(map_value, constraints, direction, config)
    else
      format_typed_map(map_value, constraints, direction, config)
    end
  end

  defp format_keyword(value, constraints, direction, config) when is_map(value) do
    instance_of = Keyword.get(constraints, :instance_of)
    field_names_callback = Map.get(config, :field_names_callback, :interop_field_names)

    if has_field_names_callback?(instance_of, field_names_callback) do
      format_typed_struct(value, constraints, direction, config)
    else
      format_typed_map(value, constraints, direction, config)
    end
  end

  defp format_keyword(value, _constraints, _direction, _config), do: value

  # ---------------------------------------------------------------------------
  # Union Handler
  # ---------------------------------------------------------------------------

  defp format_union(nil, _constraints, _direction, _config), do: nil

  defp format_union(value, constraints, direction, config) do
    union_types = Keyword.get(constraints, :types, [])

    case direction do
      :input -> format_union_input(value, union_types, config)
      :output -> format_union_output(value, union_types, constraints, config)
    end
  end

  defp format_union_input(value, union_types, config) do
    case identify_union_member(value, union_types, config) do
      {:ok, {member_name, member_spec}} ->
        member_type = Keyword.get(member_spec, :type)
        member_constraints = Keyword.get(member_spec, :constraints, [])
        client_key = find_client_key_for_member(value, member_name, config)
        member_value = Map.get(value, client_key)
        formatted_value = format(member_value, member_type, member_constraints, :input, config)
        maybe_inject_tag(formatted_value, member_spec)

      {:error, error} ->
        throw(error)
    end
  end

  defp format_union_output(value, union_types, constraints, config) do
    storage_type = Keyword.get(constraints, :storage)
    formatter = Map.get(config, :output_field_formatter, :camel_case)

    case find_union_member(value, union_types) do
      {member_name, member_spec} ->
        member_type = Keyword.get(member_spec, :type)
        member_constraints = Keyword.get(member_spec, :constraints, [])

        member_data =
          extract_union_member_data(value, member_name, member_spec, storage_type, formatter)

        formatted_member_value =
          format(member_data, member_type, member_constraints, :output, config)

        formatted_member_name = FieldFormatter.format_field_name(member_name, formatter)
        %{formatted_member_name => formatted_member_value}

      nil ->
        %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Array Handler
  # ---------------------------------------------------------------------------

  defp format_array(value, inner_type, inner_constraints, direction, config)
       when is_list(value) do
    Enum.map(value, fn item ->
      format(item, inner_type, inner_constraints, direction, config)
    end)
  end

  defp format_array(value, _inner_type, _inner_constraints, _direction, _config), do: value

  # ---------------------------------------------------------------------------
  # Union Helper Functions
  # ---------------------------------------------------------------------------

  defp identify_union_member(%{} = map, union_types, config) do
    case identify_tagged_union_member(map, union_types, config) do
      {:ok, member} ->
        {:ok, member}

      :not_found ->
        identify_key_based_union_member(map, union_types, config)
    end
  end

  defp identify_union_member(_value, _union_types, _config) do
    {:error, {:invalid_union_input, :not_a_map}}
  end

  defp identify_tagged_union_member(map, union_types, config) do
    formatter = Map.get(config, :input_field_formatter, :camel_case)

    case Enum.find_value(union_types, fn {_member_name, member_spec} = member ->
           with tag_field when not is_nil(tag_field) <- Keyword.get(member_spec, :tag),
                tag_value <- Keyword.get(member_spec, :tag_value),
                true <- has_matching_tag?(map, tag_field, tag_value, formatter) do
             member
           else
             _ -> nil
           end
         end) do
      nil -> :not_found
      member -> {:ok, member}
    end
  end

  defp identify_key_based_union_member(map, union_types, config) do
    output_formatter = Map.get(config, :output_field_formatter, :camel_case)
    input_formatter = Map.get(config, :input_field_formatter, :camel_case)

    member_names =
      Enum.map(union_types, fn {name, _} ->
        FieldFormatter.format_field_name(to_string(name), output_formatter)
      end)

    matching_members =
      Enum.filter(union_types, fn {member_name, _member_spec} ->
        Enum.any?(Map.keys(map), fn client_key ->
          internal_key = FieldFormatter.parse_input_field(client_key, input_formatter)
          to_string(internal_key) == to_string(member_name)
        end)
      end)

    case matching_members do
      [] ->
        {:error, {:invalid_union_input, :no_member_key, member_names}}

      [single_member] ->
        {:ok, single_member}

      multiple_members ->
        found_keys =
          Enum.map(multiple_members, fn {name, _} ->
            FieldFormatter.format_field_name(to_string(name), output_formatter)
          end)

        {:error, {:invalid_union_input, :multiple_member_keys, found_keys, member_names}}
    end
  end

  defp has_matching_tag?(map, tag_field, tag_value, formatter) do
    Enum.any?(map, fn {key, value} ->
      internal_key = FieldFormatter.parse_input_field(key, formatter)
      internal_key == tag_field && value == tag_value
    end)
  end

  defp find_client_key_for_member(map, member_name, config) do
    formatter = Map.get(config, :input_field_formatter, :camel_case)

    Enum.find(Map.keys(map), fn key ->
      internal_key = FieldFormatter.parse_input_field(key, formatter)
      internal_key == member_name or to_string(internal_key) == to_string(member_name)
    end)
  end

  defp find_union_member(data, union_types) do
    map_keys = MapSet.new(Map.keys(data))

    Enum.find(union_types, fn {member_name, _member_spec} ->
      MapSet.member?(map_keys, member_name)
    end)
  end

  defp extract_union_member_data(data, member_name, member_spec, storage_type, formatter) do
    case storage_type do
      :type_and_value ->
        data[member_name]

      :map_with_tag ->
        tag_field = Keyword.get(member_spec, :tag)
        member_data = data[member_name]

        if tag_field && Map.has_key?(member_data, tag_field) do
          tag_value = Map.get(member_data, tag_field)
          formatted_tag_field = FieldFormatter.format_field_name(tag_field, formatter)

          member_data
          |> Map.delete(tag_field)
          |> Map.put(formatted_tag_field, tag_value)
        else
          member_data
        end

      _ ->
        data[member_name]
    end
  end

  defp maybe_inject_tag(formatted_value, member_spec) when is_map(formatted_value) do
    tag_field = Keyword.get(member_spec, :tag)
    tag_value = Keyword.get(member_spec, :tag_value)

    if tag_field && tag_value do
      Map.put(formatted_value, tag_field, tag_value)
    else
      formatted_value
    end
  end

  defp maybe_inject_tag(value, _member_spec), do: value

  # ---------------------------------------------------------------------------
  # Helper Functions
  # ---------------------------------------------------------------------------

  defp get_formatter(:input, config), do: Map.get(config, :input_field_formatter, :camel_case)
  defp get_formatter(:output, config), do: Map.get(config, :output_field_formatter, :camel_case)

  defp format_field_for_client(field_name, resource, formatter, config) do
    # Use language-specific callback if provided
    format_callback = Map.get(config, :format_field_for_client)

    if is_function(format_callback, 3) do
      format_callback.(field_name, resource, formatter)
    else
      # Default: just use the formatter
      FieldFormatter.format_field_name(field_name, formatter)
    end
  end
end
