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

    # Optional: function returning the declared action entrypoints, as
    # %{resource: module, action: atom} maps or {module, atom} tuples.
    # Supplying it scopes discovery to those actions; omitting it keeps every
    # public action and field of every RPC resource in scope.
    get_rpc_action_entrypoints: fn otp_app -> [...] end,

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
  - `{:action, :action_name}` - Action
  - `{:argument, :argument_name}` - Action or calculation argument
  - `{:metadata, :metadata_name}` - Action metadata
  - `:returns` - Generic action return type

  ## Reading a manifest

  Every introspection read goes through `AshIntrospection.ResourceInfo`, and
  every one of them is now handed the config map, so a config carrying
  `:manifest` discovers against the manifest and a config without one
  discovers live. Both answers are the same answer:
  `test/ash_introspection/manifest/codegen_differential_test.exs` runs the
  whole public surface of this module both ways over `test/support/` and
  compares the results byte for byte.

  Two things change when a manifest is present.

    * **Entrypoints come from the manifest.** `manifest.entrypoints` already
      carries the `{resource, action}` pairs the `get_rpc_action_entrypoints`
      callback was invented to supply, so the callback is not consulted and
      `get_rpc_resources` is not required. Ports the decision in
      `ash_typescript` `32bf3fc`: resolve what to generate from the manifest,
      not from `otp_app`.
    * **Scoping is the manifest's.** `ResourceInfo.declared_resource?/2`
      answers `false` for a module the manifest does not carry, so a type
      nobody exposed stops the traversal instead of pulling its whole
      resource in.

  Issue #23's stage 4 deletes this module and replaces the traversal with
  `Ash.Info.Manifest.Generator.Reachability`, which reaches more than this does
  — accepted attributes, action metadata and transitive relationship depth.
  That deletion is breaking and is a separate pull request; this one proves the
  manifest can already answer everything the traversal asks.
  """

  alias AshIntrospection.ResourceInfo
  alias AshIntrospection.TypeSystem.Introspection

  @type config :: %{
          optional(:get_rpc_resources) => (atom() -> [module()]),
          optional(:get_rpc_action_entrypoints) => (atom() -> [map() | {module(), atom()}]),
          optional(:field_names_callback) => atom(),
          optional(:has_language_extension?) => (module() -> boolean()),
          optional(:language_name) => String.t()
        }

  @doc """
  Finds all Ash resources referenced by RPC resources.

  Recursively scans the public attributes, calculations (with their arguments)
  and aggregates of each entrypoint resource, plus each entrypoint action's
  arguments, `:returns` type and metadata, traversing complex types like maps
  with fields, unions and typed structs to find any Ash resource references.

  Entrypoints come from `config[:manifest]` when the config carries one, from
  `get_rpc_action_entrypoints` when it does not, and otherwise from
  `get_rpc_resources` with every public action in scope.

  ## Parameters

    * `otp_app` - The OTP application name to scan for domains and RPC resources
    * `config` - Configuration map carrying a `:manifest`, or a
      `get_rpc_resources` callback

  ## Returns

  A list of unique Ash resource modules that are referenced by RPC resources.
  """
  def scan_rpc_resources(otp_app, config) do
    otp_app
    |> discovery_entrypoints(config)
    |> Enum.reduce({[], MapSet.new()}, fn {resource, action_scope}, {acc, visited} ->
      {found, new_visited} = scan_entrypoint(resource, action_scope, visited, config)
      {acc ++ found, new_visited}
    end)
    |> elem(0)
    |> Enum.map(fn {resource, _path} -> resource end)
    |> Enum.uniq()
  end

  # Returns `[{resource, action_scope}]` in declaration order, where the scope is
  # either `:all_actions` or an explicit list of action names.
  #
  # A manifest wins over both callbacks: it carries the declared entrypoints
  # already, and a config that has one has no reason to compute them twice.
  defp discovery_entrypoints(otp_app, config) do
    case entrypoint_pairs(otp_app, config) do
      nil ->
        get_rpc_resources = Map.fetch!(config, :get_rpc_resources)

        Enum.map(get_rpc_resources.(otp_app), &{&1, :all_actions})

      pairs ->
        by_resource = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))

        pairs
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.map(fn resource -> {resource, Enum.uniq(by_resource[resource])} end)
    end
  end

  # The declared `{resource, action}` pairs, or `nil` when nothing declares
  # any and every public action of every RPC resource is in scope.
  defp entrypoint_pairs(otp_app, config) do
    case ResourceInfo.source(config) do
      nil ->
        case Map.get(config, :get_rpc_action_entrypoints) do
          nil -> nil
          callback -> otp_app |> callback.() |> Enum.flat_map(&normalize_entrypoint/1)
        end

      source ->
        Enum.map(source.manifest.entrypoints, &{&1.resource, &1.action.name})
    end
  end

  # The resources a client may call into.
  #
  # `get_rpc_resources` wins whenever the config carries it, including
  # alongside a manifest, because it answers a different question: what the
  # consumer listed, not what has an entrypoint. A resource listed with no
  # exposed action is in the first answer and not the second, and the warnings
  # built on this would newly accuse it. Only a config with no callback at all
  # — the manifest-only shape — falls back to the entrypoints.
  defp rpc_resources(otp_app, config) do
    with nil <- Map.get(config, :get_rpc_resources),
         pairs when is_list(pairs) <- entrypoint_pairs(otp_app, config) do
      pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    else
      nil -> Map.fetch!(config, :get_rpc_resources)
      get_rpc_resources -> get_rpc_resources.(otp_app)
    end
  end

  defp normalize_entrypoint(%{resource: resource, action: action}), do: [{resource, action}]

  defp normalize_entrypoint({resource, action}) when is_atom(resource) and is_atom(action),
    do: [{resource, action}]

  defp normalize_entrypoint(_), do: []

  @doc """
  Discovers embedded resources from RPC resources by scanning and filtering.

  When `config` carries a `:manifest` or `get_rpc_action_entrypoints`, only the
  declared actions are treated as entrypoints: a resource exposing nothing but
  a generic action contributes only what that action names, not every embedded
  type hanging off its attributes. With neither, every public action and field
  of every RPC resource is in scope.

  ## Parameters

    * `otp_app` - The OTP application name
    * `config` - Configuration map

  ## Returns

  A list of embedded resource modules.
  """
  def find_embedded_resources(otp_app, config) do
    otp_app
    |> scan_rpc_resources(config)
    |> Enum.filter(&Introspection.is_embedded_resource?(&1, config))
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
    |> Enum.flat_map(
      &extract_field_constrained_types_from_resource(&1, field_names_callback, config)
    )
    |> Enum.uniq_by(fn type_info -> type_info.instance_of end)
  end

  @doc """
  Scans a single resource to find all referenced resources.

  Covers the resource's public attributes, calculations (including their
  arguments) and aggregates, plus every public action's arguments, `:returns`
  type and metadata. An action is part of a resource's public surface, so a
  type it names is a type the client has to be able to build or read.

  ## Parameters

    * `resource` - An Ash resource module
    * `visited` - A MapSet of already-visited resources (defaults to empty)
    * `config` - Configuration map; a `:manifest` on it is what the reads use

  ## Returns

  A tuple of `{found_resources, updated_visited}` where:
    * `found_resources` - List of `{resource, path}` tuples
    * `updated_visited` - Updated MapSet of visited resources
  """
  def scan_rpc_resource(resource, visited \\ MapSet.new(), config \\ %{}) do
    scan_entrypoint(resource, :all_actions, visited, config)
  end

  defp scan_entrypoint(resource, action_scope, visited, config) do
    path = [{:root, resource}]
    actions = entrypoint_actions(resource, action_scope, config)

    {field_resources, visited} =
      if scan_resource_fields?(action_scope, actions) do
        find_referenced_resources_with_visited(resource, path, visited, config)
      else
        {[], visited}
      end

    {action_resources, visited} = traverse_actions(actions, path, visited, config)

    {field_resources ++ action_resources, visited}
  end

  defp entrypoint_actions(resource, :all_actions, config) do
    resource
    |> ResourceInfo.actions(config)
    |> Enum.filter(&Map.get(&1, :public?, true))
  end

  defp entrypoint_actions(resource, action_names, config) when is_list(action_names) do
    action_names
    |> Enum.map(&ResourceInfo.action(resource, &1, config))
    |> Enum.reject(&is_nil/1)
  end

  # A read, create, update or destroy action hands back the resource itself, so
  # its attributes, calculations and aggregates are all reachable. A generic
  # action reaches only what it names.
  defp scan_resource_fields?(:all_actions, _actions), do: true

  defp scan_resource_fields?(action_names, actions) when is_list(action_names) do
    Enum.any?(actions, &(&1.type != :action))
  end

  defp traverse_actions(actions, current_path, visited, config) do
    Enum.reduce(actions, {[], visited}, fn action, {acc, visited} ->
      {found, visited} = traverse_action(action, current_path, visited, config)
      {acc ++ found, visited}
    end)
  end

  defp traverse_action(action, current_path, visited, config) do
    action_path = current_path ++ [{:action, action.name}]

    {argument_resources, visited} =
      action.arguments
      |> Enum.filter(&Map.get(&1, :public?, true))
      |> Enum.reduce({[], visited}, fn argument, {acc, visited} ->
        {found, visited} =
          traverse_type_with_visited(
            argument.type,
            argument.constraints || [],
            action_path ++ [{:argument, argument.name}],
            visited,
            config
          )

        {acc ++ found, visited}
      end)

    {return_resources, visited} =
      case Map.get(action, :returns) do
        nil ->
          {[], visited}

        returns ->
          traverse_type_with_visited(
            returns,
            Map.get(action, :constraints) || [],
            action_path ++ [:returns],
            visited,
            config
          )
      end

    {metadata_resources, visited} =
      (Map.get(action, :metadata) || [])
      |> Enum.reduce({[], visited}, fn metadata, {acc, visited} ->
        {found, visited} =
          traverse_type_with_visited(
            metadata.type,
            metadata.constraints || [],
            action_path ++ [{:metadata, metadata.name}],
            visited,
            config
          )

        {acc ++ found, visited}
      end)

    {argument_resources ++ return_resources ++ metadata_resources, visited}
  end

  @doc """
  Finds all embedded resources referenced by a single resource.

  ## Parameters

    * `resource` - An Ash resource module to scan

  ## Returns

  A list of embedded resource modules.
  """
  def find_referenced_embedded_resources(resource, config \\ %{}) do
    resource
    |> find_referenced_resources(config)
    |> Enum.filter(&ResourceInfo.embedded?(&1, config))
  end

  @doc """
  Finds all non-embedded resources referenced by a single resource.

  ## Parameters

    * `resource` - An Ash resource module to scan

  ## Returns

  A list of non-embedded resource modules.
  """
  def find_referenced_non_embedded_resources(resource, config \\ %{}) do
    resource
    |> find_referenced_resources(config)
    |> Enum.reject(&ResourceInfo.embedded?(&1, config))
  end

  @doc """
  Finds all Ash resources referenced by a single resource's public attributes,
  calculations, and aggregates.

  ## Parameters

    * `resource` - An Ash resource module to scan

  ## Returns

  A list of Ash resource modules referenced by the given resource.
  """
  def find_referenced_resources(resource, config \\ %{}) do
    path = [{:root, resource}]

    find_referenced_resources_with_visited(resource, path, MapSet.new(), config)
    |> elem(0)
    |> Enum.map(fn {res, _path} -> res end)
    |> Enum.uniq()
  end

  @doc """
  Finds all non-RPC resources that are referenced by RPC resources.

  These are resources that appear in attributes, calculations, or aggregates
  of RPC resources but are not themselves configured as RPC resources. With a
  manifest, "RPC resource" means a resource with a declared entrypoint; without
  one it means whatever `get_rpc_resources` returns.

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
    rpc_resources = rpc_resources(otp_app, config)

    rpc_resources
    |> Enum.flat_map(fn rpc_resource ->
      path = [{:root, rpc_resource}]

      rpc_resource
      |> find_referenced_resources_with_visited(path, MapSet.new(), config)
      |> elem(0)
    end)
    |> Enum.reject(fn {resource, _path} ->
      resource in rpc_resources or ResourceInfo.embedded?(resource, config)
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

  A manifest cannot answer the first half of this question. It carries what was
  declared, and this asks what was *not* — so the extension scan stays live
  over `Ash.Info.domains/1` whether or not a manifest is present, and only the
  set it rejects against comes from the manifest's entrypoints.
  """
  def find_resources_missing_from_rpc_config(otp_app, config) do
    has_extension? = Map.get(config, :has_language_extension?, fn _ -> false end)

    rpc_resources = rpc_resources(otp_app, config)

    all_resources_with_extension =
      otp_app
      |> Ash.Info.domains()
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.uniq()
      |> Enum.filter(has_extension?)

    Enum.reject(all_resources_with_extension, fn resource ->
      ResourceInfo.embedded?(resource, config) or resource in rpc_resources
    end)
  end

  @doc """
  Finds all Ash resources used as struct arguments in RPC actions.

  Scans the given actions' public arguments for:

    * `:struct` or `Ash.Type.Struct` with an `instance_of` constraint pointing
      at an Ash resource,
    * an embedded resource named directly as the argument's type,
    * either of the above behind a NewType wrapper or an array.

  Embedded resources are included. A generator that skipped them produced no
  type for an argument a client has to construct.

  ## Parameters

    * `actions` - A list of action structs to scan

  ## Returns

  A list of unique Ash resource modules used as struct arguments.
  """
  def find_struct_argument_resources(actions, config \\ %{}) when is_list(actions) do
    actions
    |> Enum.flat_map(fn action ->
      arguments =
        action.arguments
        |> Enum.filter(fn arg -> Map.get(arg, :public?, true) end)

      find_struct_resources_in_arguments(arguments, config)
    end)
    |> Enum.uniq()
  end

  defp find_struct_resources_in_arguments(arguments, config) when is_list(arguments) do
    arguments
    |> Enum.flat_map(fn arg ->
      find_struct_resources_in_type(arg.type, arg.constraints || [], config)
    end)
  end

  defp find_struct_resources_in_type(type, constraints, config) do
    {type, constraints} = Introspection.unwrap_new_type(type, constraints)

    cond do
      match?({:array, _}, type) ->
        {:array, inner_type} = type
        find_struct_resources_in_type(inner_type, Keyword.get(constraints, :items, []), config)

      # An embedded resource is a type in its own right, so an argument can name
      # it directly rather than going through `Ash.Type.Struct`.
      Introspection.is_embedded_resource?(type, config) ->
        [type]

      type in [Ash.Type.Struct, :struct] ->
        instance_of = Keyword.get(constraints, :instance_of)

        if instance_of && ResourceInfo.declared_resource?(instance_of, config) do
          [instance_of]
        else
          []
        end

      true ->
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
  def traverse_type(type, constraints, config \\ %{})

  def traverse_type(type, constraints, config) when is_list(constraints) do
    traverse_type_with_visited(type, constraints, [], MapSet.new(), config)
    |> elem(0)
    |> Enum.map(fn {resource, _path} -> resource end)
    |> Enum.uniq()
  end

  def traverse_type(_type, _constraints, _config), do: []

  @doc """
  Traverses a fields keyword list (from Map/Keyword/Tuple/custom type constraints)
  to find any Ash resource references in the nested field types.

  ## Parameters

    * `fields` - A keyword list where keys are field names and values are field configs

  ## Returns

  A list of Ash resource modules found in the field definitions.
  """
  def traverse_fields(fields, config \\ %{})

  def traverse_fields(fields, config) when is_list(fields) do
    traverse_fields_with_visited(fields, [], MapSet.new(), config)
    |> elem(0)
    |> Enum.map(fn {resource, _path} -> resource end)
    |> Enum.uniq()
  end

  def traverse_fields(_, _config), do: []

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
  defp format_path_segment({:action, name}), do: "(action: #{name})"
  defp format_path_segment({:argument, name}), do: "(argument: #{name})"
  defp format_path_segment({:metadata, name}), do: "(metadata: #{name})"
  defp format_path_segment(:returns), do: "(returns)"

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

  defp extract_field_constrained_types_from_resource(resource, field_names_callback, config) do
    resource
    |> ResourceInfo.public_attributes(config)
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
      if instance_of && Code.ensure_loaded?(instance_of) &&
           function_exported?(instance_of, field_names_callback, 0) do
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

  defp get_related_resource(resource, relationship_path, config) do
    Enum.reduce_while(relationship_path, resource, fn rel_name, current_resource ->
      case ResourceInfo.relationship(current_resource, rel_name, config) do
        nil -> {:halt, nil}
        relationship -> {:cont, relationship.destination}
      end
    end)
  end

  defp find_referenced_resources_with_visited(resource, current_path, visited, config) do
    if MapSet.member?(visited, resource) do
      {[], visited}
    else
      visited = MapSet.put(visited, resource)

      attributes = ResourceInfo.public_attributes(resource, config)
      calculations = ResourceInfo.public_calculations(resource, config)
      aggregates = ResourceInfo.public_aggregates(resource, config)

      {attribute_resources, visited} =
        Enum.reduce(attributes, {[], visited}, fn attr, {acc, visited} ->
          attr_path = current_path ++ [{:attribute, attr.name}]

          {found, new_visited} =
            traverse_type_with_visited(
              attr.type,
              attr.constraints || [],
              attr_path,
              visited,
              config
            )

          {acc ++ found, new_visited}
        end)

      {calculation_resources, visited} =
        Enum.reduce(calculations, {[], visited}, fn calc, {acc, visited} ->
          calc_path = current_path ++ [{:calculation, calc.name}]

          {found, visited} =
            traverse_type_with_visited(
              calc.type,
              calc.constraints || [],
              calc_path,
              visited,
              config
            )

          # A calculation argument is client-supplied, so its type needs
          # generating even when nothing else in the resource mentions it.
          {argument_found, visited} =
            (Map.get(calc, :arguments) || [])
            |> Enum.reduce({[], visited}, fn argument, {arg_acc, visited} ->
              {found, visited} =
                traverse_type_with_visited(
                  argument.type,
                  argument.constraints || [],
                  calc_path ++ [{:argument, argument.name}],
                  visited,
                  config
                )

              {arg_acc ++ found, visited}
            end)

          {acc ++ found ++ argument_found, visited}
        end)

      {aggregate_resources, visited} =
        Enum.reduce(aggregates, {[], visited}, fn agg, {acc, visited} ->
          with true <- agg.kind in [:first, :list, :max, :min, :custom],
               true <- agg.field != nil and agg.relationship_path != [],
               related_resource when not is_nil(related_resource) <-
                 get_related_resource(resource, agg.relationship_path, config),
               field_attr when not is_nil(field_attr) <-
                 ResourceInfo.attribute(related_resource, agg.field, config) do
            agg_path =
              current_path ++
                [{:aggregate, agg.name}, {:relationship_path, agg.relationship_path}]

            {found, new_visited} =
              traverse_type_with_visited(
                field_attr.type,
                field_attr.constraints || [],
                agg_path,
                visited,
                config
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

  defp traverse_type_with_visited(type, constraints, current_path, visited, config)
       when is_list(constraints) do
    # A NewType keeps its own constraints, so the wrapper's raw constraints are
    # empty and every `:types`, `:fields` and `:instance_of` below would read as
    # missing. Unwrap before matching on the type.
    {type, constraints} = Introspection.unwrap_new_type(type, constraints)

    case type do
      {:array, inner_type} ->
        items_constraints = Keyword.get(constraints, :items, [])
        array_path = current_path ++ [:array_items]
        traverse_type_with_visited(inner_type, items_constraints, array_path, visited, config)

      Ash.Type.Struct ->
        instance_of = Keyword.get(constraints, :instance_of)

        if instance_of && ResourceInfo.declared_resource?(instance_of, config) do
          resource_path = current_path

          {nested, new_visited} =
            find_referenced_resources_with_visited(instance_of, resource_path, visited, config)

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
              traverse_type_with_visited(
                member_type,
                member_constraints,
                union_path,
                visited,
                config
              )

            {acc ++ found, new_visited}
          else
            {acc, visited}
          end
        end)

      type when type in [Ash.Type.Map, Ash.Type.Keyword, Ash.Type.Tuple] ->
        fields = Keyword.get(constraints, :fields)

        if fields do
          traverse_fields_with_visited(fields, current_path, visited, config)
        else
          {[], visited}
        end

      type when is_atom(type) ->
        cond do
          ResourceInfo.declared_resource?(type, config) ->
            resource_path = current_path

            {nested, new_visited} =
              find_referenced_resources_with_visited(type, resource_path, visited, config)

            {[{type, resource_path}] ++ nested, new_visited}

          Code.ensure_loaded?(type) ->
            fields = Keyword.get(constraints, :fields)

            if fields do
              traverse_fields_with_visited(fields, current_path, visited, config)
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

  defp traverse_type_with_visited(_type, _constraints, _current_path, visited, _config),
    do: {[], visited}

  defp traverse_fields_with_visited(fields, current_path, visited, config)
       when is_list(fields) do
    Enum.reduce(fields, {[], visited}, fn {field_name, field_config}, {acc, visited} ->
      field_type = Keyword.get(field_config, :type)
      field_constraints = Keyword.get(field_config, :constraints, [])

      if field_type do
        field_path = current_path ++ [{:map_field, field_name}]

        {found, new_visited} =
          traverse_type_with_visited(field_type, field_constraints, field_path, visited, config)

        {acc ++ found, new_visited}
      else
        {acc, visited}
      end
    end)
  end

  defp traverse_fields_with_visited(_, _current_path, visited, _config), do: {[], visited}

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
