# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Codegen.TypeDiscovery do
  @moduledoc """
  Language-agnostic type discovery for Ash resources and types.

  This module provides the core type discovery logic that recursively traverses
  the type dependency tree to find all Ash resources and types that need
  code generation.

  ## Configuration

  Type discovery is configured via a config map:

  ```elixir
  %{
    # Required: function to get RPC resources from otp_app
    get_rpc_resources: fn otp_app -> [...] end,

    # Optional: callback name for field names (default: :interop_field_names)
    field_names_callback: :interop_field_names,

    # Optional: function to check if a module has the language extension
    has_language_extension?: fn resource -> true/false end,

    # Optional: language name for warnings (default: "Interop")
    language_name: "TypeScript"
  }
  ```

  ## Type Discovery

  The discovery process handles:
  - Ash resources (both embedded and non-embedded)
  - TypedStruct modules
  - Complex nested types (unions, maps, arrays, etc.)
  - Recursive type references with cycle detection
  - Path tracking for diagnostic purposes

  ## Path Tracking

  During traversal, paths are tracked as lists of segments:
  - `{:root, ResourceModule}` - Starting point
  - `{:attribute, :field_name}` - Attribute field
  - `{:calculation, :calc_name}` - Calculation
  - `{:aggregate, :agg_name}` - Aggregate
  - `{:union_member, :type_name}` - Union member
  - `{:array_items}` - Array items
  - `{:map_field, :field_name}` - Map field
  """

  alias AshIntrospection.TypeSystem.Introspection

  @type config :: %{
          optional(:get_rpc_resources) => (atom() -> [module()]),
          optional(:field_names_callback) => atom(),
          optional(:has_language_extension?) => (module() -> boolean()),
          optional(:language_name) => String.t()
        }

  @doc """
  Finds all Ash resources referenced by RPC resources.

  Recursively scans all public attributes, calculations, and aggregates of RPC resources,
  traversing complex types like maps with fields, unions, typed structs, etc., to find
  any Ash resource references.

  ## Parameters

    * `otp_app` - The OTP application name to scan for domains and RPC resources
    * `config` - Configuration map with `get_rpc_resources` callback

  ## Returns

  A list of unique Ash resource modules that are referenced by RPC resources.
  """
  def scan_rpc_resources(otp_app, config) do
    get_rpc_resources = Map.fetch!(config, :get_rpc_resources)
    rpc_resources = get_rpc_resources.(otp_app)

    rpc_resources
    |> Enum.reduce({[], MapSet.new()}, fn resource, {acc, visited} ->
      {found, new_visited} = scan_rpc_resource(resource, visited)
      {acc ++ found, new_visited}
    end)
    |> elem(0)
    |> Enum.map(fn {resource, _path} -> resource end)
    |> Enum.uniq()
  end

  @doc """
  Discovers embedded resources from RPC resources by scanning and filtering.

  ## Parameters

    * `otp_app` - The OTP application name
    * `config` - Configuration map

  ## Returns

  A list of embedded resource modules.
  """
  def find_embedded_resources(otp_app, config) do
    otp_app
    |> scan_rpc_resources(config)
    |> Enum.filter(&Introspection.is_embedded_resource?/1)
  end

  @doc """
  Discovers all types with field constraints referenced by the given resources.

  Scans public attributes of resources to find types with field constraints
  (Map with fields, Keyword with fields, Tuple with fields, Struct with fields, TypedStruct)
  in direct types, arrays, and union types.

  ## Parameters

    * `resources` - A list of Ash resource modules to scan
    * `config` - Configuration map

  ## Returns

  A list of unique type info maps containing:
    * `:instance_of` - The module (if available)
    * `:constraints` - The type constraints
    * `:field_name_mappings` - Field name mappings (if available)
  """
  def find_field_constrained_types(resources, config \\ %{}) do
    field_names_callback = Map.get(config, :field_names_callback, :interop_field_names)

    resources
    |> Enum.flat_map(&extract_field_constrained_types_from_resource(&1, field_names_callback))
    |> Enum.uniq_by(fn type_info -> type_info.instance_of end)
  end

  @doc """
  Scans a single resource to find all referenced resources.

  ## Parameters

    * `resource` - An Ash resource module
    * `visited` - A MapSet of already-visited resources (defaults to empty)

  ## Returns

  A tuple of `{found_resources, updated_visited}` where:
    * `found_resources` - List of `{resource, path}` tuples
    * `updated_visited` - Updated MapSet of visited resources
  """
  def scan_rpc_resource(resource, visited \\ MapSet.new()) do
    path = [{:root, resource}]
    find_referenced_resources_with_visited(resource, path, visited)
  end

  @doc """
  Finds all embedded resources referenced by a single resource.

  ## Parameters

    * `resource` - An Ash resource module to scan

  ## Returns

  A list of embedded resource modules.
  """
  def find_referenced_embedded_resources(resource) do
    resource
    |> find_referenced_resources()
    |> Enum.filter(&Ash.Resource.Info.embedded?/1)
  end

  @doc """
  Finds all non-embedded resources referenced by a single resource.

  ## Parameters

    * `resource` - An Ash resource module to scan

  ## Returns

  A list of non-embedded resource modules.
  """
  def find_referenced_non_embedded_resources(resource) do
    resource
    |> find_referenced_resources()
    |> Enum.reject(&Ash.Resource.Info.embedded?/1)
  end

  @doc """
  Finds all Ash resources referenced by a single resource's public attributes,
  calculations, and aggregates.

  ## Parameters

    * `resource` - An Ash resource module to scan

  ## Returns

  A list of Ash resource modules referenced by the given resource.
  """
  def find_referenced_resources(resource) do
    path = [{:root, resource}]

    find_referenced_resources_with_visited(resource, path, MapSet.new())
    |> elem(0)
    |> Enum.map(fn {res, _path} -> res end)
    |> Enum.uniq()
  end

  @doc """
  Finds all non-RPC resources that are referenced by RPC resources.

  These are resources that appear in attributes, calculations, or aggregates
  of RPC resources but are not themselves configured as RPC resources.

  ## Parameters

    * `otp_app` - The OTP application name
    * `config` - Configuration map

  ## Returns

  A list of non-RPC resource modules that are referenced by RPC resources.
  """
  def find_non_rpc_referenced_resources(otp_app, config) do
    otp_app
    |> find_non_rpc_referenced_resources_with_paths(config)
    |> Map.keys()
  end

  @doc """
  Finds all non-RPC resources referenced by RPC resources, with paths showing where they're referenced.

  ## Parameters

    * `otp_app` - The OTP application name
    * `config` - Configuration map

  ## Returns

  A map where keys are non-RPC resource modules and values are lists of formatted path strings
  showing where each resource is referenced.
  """
  def find_non_rpc_referenced_resources_with_paths(otp_app, config) do
    get_rpc_resources = Map.fetch!(config, :get_rpc_resources)
    rpc_resources = get_rpc_resources.(otp_app)

    rpc_resources
    |> Enum.flat_map(fn rpc_resource ->
      path = [{:root, rpc_resource}]

      rpc_resource
      |> find_referenced_resources_with_visited(path, MapSet.new())
      |> elem(0)
    end)
    |> Enum.reject(fn {resource, _path} ->
      resource in rpc_resources or Ash.Resource.Info.embedded?(resource)
    end)
    |> group_by_resource_with_paths()
  end

  @doc """
  Finds resources with a language extension that are not configured
  in any RPC block.

  ## Parameters

    * `otp_app` - The OTP application name
    * `config` - Configuration map with `get_rpc_resources` and `has_language_extension?`

  ## Returns

  A list of non-embedded resource modules with the extension but not configured for RPC.
  """
  def find_resources_missing_from_rpc_config(otp_app, config) do
    get_rpc_resources = Map.fetch!(config, :get_rpc_resources)
    has_extension? = Map.get(config, :has_language_extension?, fn _ -> false end)

    rpc_resources = get_rpc_resources.(otp_app)

    all_resources_with_extension =
      otp_app
      |> Ash.Info.domains()
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.uniq()
      |> Enum.filter(has_extension?)

    Enum.reject(all_resources_with_extension, fn resource ->
      Ash.Resource.Info.embedded?(resource) or resource in rpc_resources
    end)
  end

  @doc """
  Finds all Ash resources used as struct arguments in RPC actions.

  Scans all RPC actions for arguments with type `:struct` or `Ash.Type.Struct`
  that have an `instance_of` constraint pointing to an Ash resource.

  ## Parameters

    * `otp_app` - The OTP application name
    * `config` - Configuration map with `get_rpc_action_info`

  ## Returns

  A list of unique Ash resource modules used as struct arguments.
  """
  def find_struct_argument_resources(actions) when is_list(actions) do
    actions
    |> Enum.flat_map(fn action ->
      arguments =
        action.arguments
        |> Enum.filter(fn arg -> Map.get(arg, :public?, true) end)

      find_struct_resources_in_arguments(arguments)
    end)
    |> Enum.uniq()
  end

  defp find_struct_resources_in_arguments(arguments) when is_list(arguments) do
    arguments
    |> Enum.flat_map(fn arg ->
      find_struct_resources_in_type(arg.type, arg.constraints || [])
    end)
  end

  defp find_struct_resources_in_type(type, constraints) do
    case type do
      Ash.Type.Struct ->
        instance_of = Keyword.get(constraints, :instance_of)

        if instance_of && Spark.Dsl.is?(instance_of, Ash.Resource) &&
             !Introspection.is_embedded_resource?(instance_of) do
          [instance_of]
        else
          []
        end

      :struct ->
        instance_of = Keyword.get(constraints, :instance_of)

        if instance_of && Spark.Dsl.is?(instance_of, Ash.Resource) &&
             !Introspection.is_embedded_resource?(instance_of) do
          [instance_of]
        else
          []
        end

      {:array, inner_type} ->
        items_constraints = Keyword.get(constraints, :items, [])
        find_struct_resources_in_type(inner_type, items_constraints)

      _ ->
        []
    end
  end

  @doc """
  Recursively traverses a type and its constraints to find all Ash resource references.

  This function handles:
  - Direct Ash resource module references
  - Ash.Type.Struct with instance_of constraint
  - Ash.Type.Union with multiple type members
  - Ash.Type.Map, Ash.Type.Keyword, Ash.Type.Tuple with fields constraints
  - Custom types with fields constraints
  - Arrays of any of the above

  ## Parameters

    * `type` - The type to traverse (module or type atom)
    * `constraints` - The constraints keyword list for the type

  ## Returns

  A list of Ash resource modules found in the type tree.
  """
  def traverse_type(type, constraints) when is_list(constraints) do
    traverse_type_with_visited(type, constraints, [], MapSet.new())
    |> elem(0)
    |> Enum.map(fn {resource, _path} -> resource end)
    |> Enum.uniq()
  end

  def traverse_type(_type, _constraints), do: []

  @doc """
  Traverses a fields keyword list (from Map/Keyword/Tuple/custom type constraints)
  to find any Ash resource references in the nested field types.

  ## Parameters

    * `fields` - A keyword list where keys are field names and values are field configs

  ## Returns

  A list of Ash resource modules found in the field definitions.
  """
  def traverse_fields(fields) when is_list(fields) do
    traverse_fields_with_visited(fields, [], MapSet.new())
    |> elem(0)
    |> Enum.map(fn {resource, _path} -> resource end)
    |> Enum.uniq()
  end

  def traverse_fields(_), do: []

  @doc """
  Formats a path (list of path segments) into a human-readable string.

  ## Parameters

    * `path` - A list of path segments

  ## Returns

  A formatted string representing the path.

  ## Examples

      iex> path = [{:root, MyApp.Todo}, {:attribute, :metadata}, {:union_member, :text}]
      iex> TypeDiscovery.format_path(path)
      "Todo -> metadata -> (union: text)"
  """
  def format_path(path) do
    Enum.map_join(path, " -> ", &format_path_segment/1)
  end

  defp format_path_segment({:root, module}) do
    module
    |> Module.split()
    |> List.last()
  end

  defp format_path_segment({:attribute, name}), do: to_string(name)
  defp format_path_segment({:calculation, name}), do: to_string(name)
  defp format_path_segment({:aggregate, name}), do: to_string(name)
  defp format_path_segment({:union_member, name}), do: "(union member: #{name})"
  defp format_path_segment(:array_items), do: "[]"
  defp format_path_segment({:map_field, name}), do: to_string(name)

  defp format_path_segment({:relationship_path, names}) do
    "(via relationships: #{Enum.join(names, " -> ")})"
  end

  defp group_by_resource_with_paths(resource_path_tuples) do
    resource_path_tuples
    |> Enum.group_by(
      fn {resource, _path} -> resource end,
      fn {_resource, path} -> format_path(path) end
    )
    |> Enum.map(fn {resource, paths} -> {resource, Enum.uniq(paths)} end)
    |> Enum.into(%{})
  end

  defp extract_field_constrained_types_from_resource(resource, field_names_callback) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Enum.filter(&has_field_constraints?/1)
    |> Enum.flat_map(&extract_field_constrained_type_info(&1, field_names_callback))
    |> Enum.filter(fn type_info -> type_info.instance_of != nil end)
  end

  defp has_field_constraints?(%Ash.Resource.Attribute{
         type: type,
         constraints: constraints
       }) do
    case type do
      Ash.Type.Union ->
        union_types = Introspection.get_union_types_from_constraints(type, constraints)

        Enum.any?(union_types, fn {_type_name, type_config} ->
          member_constraints = Keyword.get(type_config, :constraints, [])

          Keyword.has_key?(member_constraints, :fields) and
            Keyword.has_key?(member_constraints, :instance_of)
        end)

      {:array, Ash.Type.Union} ->
        items_constraints = Keyword.get(constraints, :items, [])

        union_types =
          Introspection.get_union_types_from_constraints(Ash.Type.Union, items_constraints)

        Enum.any?(union_types, fn {_type_name, type_config} ->
          member_constraints = Keyword.get(type_config, :constraints, [])

          Keyword.has_key?(member_constraints, :fields) and
            Keyword.has_key?(member_constraints, :instance_of)
        end)

      _ ->
        Keyword.has_key?(constraints, :fields) and Keyword.has_key?(constraints, :instance_of)
    end
  end

  defp has_field_constraints?(_), do: false

  defp extract_field_constrained_type_info(
         %Ash.Resource.Attribute{type: type, constraints: constraints},
         field_names_callback
       ) do
    case type do
      Ash.Type.Union ->
        union_types = Introspection.get_union_types_from_constraints(type, constraints)

        Enum.flat_map(union_types, fn {_type_name, type_config} ->
          member_constraints = Keyword.get(type_config, :constraints, [])

          if Keyword.has_key?(member_constraints, :fields) and
               Keyword.has_key?(member_constraints, :instance_of) do
            [build_type_info(member_constraints, field_names_callback)]
          else
            []
          end
        end)

      {:array, Ash.Type.Union} ->
        items_constraints = Keyword.get(constraints, :items, [])

        union_types =
          Introspection.get_union_types_from_constraints(Ash.Type.Union, items_constraints)

        Enum.flat_map(union_types, fn {_type_name, type_config} ->
          member_constraints = Keyword.get(type_config, :constraints, [])

          if Keyword.has_key?(member_constraints, :fields) and
               Keyword.has_key?(member_constraints, :instance_of) do
            [build_type_info(member_constraints, field_names_callback)]
          else
            []
          end
        end)

      _ ->
        if Keyword.has_key?(constraints, :fields) and Keyword.has_key?(constraints, :instance_of) do
          [build_type_info(constraints, field_names_callback)]
        else
          []
        end
    end
  end

  defp build_type_info(constraints, field_names_callback) do
    instance_of = Keyword.get(constraints, :instance_of)

    field_name_mappings =
      if instance_of && function_exported?(instance_of, field_names_callback, 0) do
        apply(instance_of, field_names_callback, [])
      else
        nil
      end

    %{
      instance_of: instance_of,
      constraints: constraints,
      field_name_mappings: field_name_mappings
    }
  end

  defp get_related_resource(resource, relationship_path) do
    Enum.reduce_while(relationship_path, resource, fn rel_name, current_resource ->
      case Ash.Resource.Info.relationship(current_resource, rel_name) do
        nil -> {:halt, nil}
        relationship -> {:cont, relationship.destination}
      end
    end)
  end

  defp find_referenced_resources_with_visited(resource, current_path, visited) do
    if MapSet.member?(visited, resource) do
      {[], visited}
    else
      visited = MapSet.put(visited, resource)

      attributes = Ash.Resource.Info.public_attributes(resource)
      calculations = Ash.Resource.Info.public_calculations(resource)
      aggregates = Ash.Resource.Info.public_aggregates(resource)

      {attribute_resources, visited} =
        Enum.reduce(attributes, {[], visited}, fn attr, {acc, visited} ->
          attr_path = current_path ++ [{:attribute, attr.name}]

          {found, new_visited} =
            traverse_type_with_visited(attr.type, attr.constraints || [], attr_path, visited)

          {acc ++ found, new_visited}
        end)

      {calculation_resources, visited} =
        Enum.reduce(calculations, {[], visited}, fn calc, {acc, visited} ->
          calc_path = current_path ++ [{:calculation, calc.name}]

          {found, new_visited} =
            traverse_type_with_visited(calc.type, calc.constraints || [], calc_path, visited)

          {acc ++ found, new_visited}
        end)

      {aggregate_resources, visited} =
        Enum.reduce(aggregates, {[], visited}, fn agg, {acc, visited} ->
          with true <- agg.kind in [:first, :list, :max, :min, :custom],
               true <- agg.field != nil and agg.relationship_path != [],
               related_resource when not is_nil(related_resource) <-
                 get_related_resource(resource, agg.relationship_path),
               field_attr when not is_nil(field_attr) <-
                 Ash.Resource.Info.attribute(related_resource, agg.field) do
            agg_path =
              current_path ++
                [{:aggregate, agg.name}, {:relationship_path, agg.relationship_path}]

            {found, new_visited} =
              traverse_type_with_visited(
                field_attr.type,
                field_attr.constraints || [],
                agg_path,
                visited
              )

            {acc ++ found, new_visited}
          else
            _ -> {acc, visited}
          end
        end)

      all_resources = attribute_resources ++ calculation_resources ++ aggregate_resources

      {all_resources, visited}
    end
  end

  defp traverse_type_with_visited(type, constraints, current_path, visited)
       when is_list(constraints) do
    case type do
      {:array, inner_type} ->
        items_constraints = Keyword.get(constraints, :items, [])
        array_path = current_path ++ [:array_items]
        traverse_type_with_visited(inner_type, items_constraints, array_path, visited)

      Ash.Type.Struct ->
        instance_of = Keyword.get(constraints, :instance_of)

        if instance_of && Ash.Resource.Info.resource?(instance_of) do
          resource_path = current_path

          {nested, new_visited} =
            find_referenced_resources_with_visited(instance_of, resource_path, visited)

          {[{instance_of, resource_path}] ++ nested, new_visited}
        else
          {[], visited}
        end

      Ash.Type.Union ->
        union_types = Introspection.get_union_types_from_constraints(type, constraints)

        Enum.reduce(union_types, {[], visited}, fn {type_name, type_config}, {acc, visited} ->
          member_type = Keyword.get(type_config, :type)
          member_constraints = Keyword.get(type_config, :constraints, [])

          if member_type do
            union_path = current_path ++ [{:union_member, type_name}]

            {found, new_visited} =
              traverse_type_with_visited(member_type, member_constraints, union_path, visited)

            {acc ++ found, new_visited}
          else
            {acc, visited}
          end
        end)

      type when type in [Ash.Type.Map, Ash.Type.Keyword, Ash.Type.Tuple] ->
        fields = Keyword.get(constraints, :fields)

        if fields do
          traverse_fields_with_visited(fields, current_path, visited)
        else
          {[], visited}
        end

      type when is_atom(type) ->
        cond do
          Ash.Resource.Info.resource?(type) ->
            resource_path = current_path

            {nested, new_visited} =
              find_referenced_resources_with_visited(type, resource_path, visited)

            {[{type, resource_path}] ++ nested, new_visited}

          Code.ensure_loaded?(type) ->
            fields = Keyword.get(constraints, :fields)

            if fields do
              traverse_fields_with_visited(fields, current_path, visited)
            else
              {[], visited}
            end

          true ->
            {[], visited}
        end

      _ ->
        {[], visited}
    end
  end

  defp traverse_type_with_visited(_type, _constraints, _current_path, visited),
    do: {[], visited}

  defp traverse_fields_with_visited(fields, current_path, visited) when is_list(fields) do
    Enum.reduce(fields, {[], visited}, fn {field_name, field_config}, {acc, visited} ->
      field_type = Keyword.get(field_config, :type)
      field_constraints = Keyword.get(field_config, :constraints, [])

      if field_type do
        field_path = current_path ++ [{:map_field, field_name}]

        {found, new_visited} =
          traverse_type_with_visited(field_type, field_constraints, field_path, visited)

        {acc ++ found, new_visited}
      else
        {acc, visited}
      end
    end)
  end

  defp traverse_fields_with_visited(_, _current_path, visited), do: {[], visited}

  @doc """
  Builds a formatted warning message for resources missing from RPC config.

  ## Parameters

    * `otp_app` - The OTP application name
    * `missing_resources` - List of resource modules
    * `config` - Configuration map with `language_name`

  ## Returns

  A formatted warning string.
  """
  def build_missing_config_warning(otp_app, missing_resources, config \\ %{}) do
    language_name = Map.get(config, :language_name, "Interop")

    lines = [
      "⚠️  Found resources with #{language_name} extension",
      "   but not listed in any domain's RPC block:",
      ""
    ]

    resource_lines =
      missing_resources
      |> Enum.map(fn resource -> "   • #{inspect(resource)}" end)

    explanation_lines = [
      "",
      "   These resources will not have #{language_name} types generated.",
      "   To fix this, add them to a domain's RPC block."
    ]

    example_domain =
      otp_app
      |> Ash.Info.domains()
      |> List.first()

    example_lines =
      if example_domain do
        example_resource = missing_resources |> List.first() |> inspect()

        [
          "",
          "   Example:",
          "   defmodule #{inspect(example_domain)} do",
          "     # Add resource #{example_resource} to RPC config",
          "   end"
        ]
      else
        []
      end

    (lines ++ resource_lines ++ explanation_lines ++ example_lines)
    |> Enum.join("\n")
  end

  @doc """
  Builds a warning message for non-RPC resources referenced by RPC resources.

  ## Parameters

    * `referenced_non_rpc_with_paths` - Map of resource => [paths]
    * `config` - Configuration map with `language_name`

  ## Returns

  A formatted warning string.
  """
  def build_non_rpc_references_warning(referenced_non_rpc_with_paths, config \\ %{}) do
    language_name = Map.get(config, :language_name, "Interop")

    lines = [
      "⚠️  Found non-RPC resources referenced by RPC resources:",
      ""
    ]

    resource_lines =
      referenced_non_rpc_with_paths
      |> Enum.sort_by(fn {resource, _paths} -> inspect(resource) end)
      |> Enum.flat_map(fn {resource, paths} ->
        resource_line = "   • #{inspect(resource)}"
        ref_header = "     Referenced from:"

        path_lines =
          paths
          |> Enum.sort()
          |> Enum.map(fn path -> "       - #{path}" end)

        [resource_line, ref_header] ++ path_lines ++ [""]
      end)

    explanation_lines = [
      "   These resources are referenced in attributes, calculations, or aggregates",
      "   of RPC resources, but are not themselves configured as RPC resources.",
      "   They will NOT have #{language_name} types or RPC functions generated."
    ]

    (lines ++ resource_lines ++ explanation_lines)
    |> Enum.join("\n")
  end
end
