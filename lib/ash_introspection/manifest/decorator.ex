# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Manifest.Decorator do
  @moduledoc """
  Walks a freshly generated `%Ash.Info.Manifest{}` once, at compile time, and
  writes everything this library reads under `custom.<namespace>`.

  This is the only module in `lib/` that is meant to call `Ash.Resource.Info`
  during decoration, and the only one that writes `:custom`.
  `AshIntrospection.Manifest.Custom` reads it back. The point of the split is
  that the request path stops introspecting: live introspection is not deleted
  by adopting a manifest, it is relocated to one compile-time pass.

  ## Why the Ash structs are carried, not rebuilt

  A `%Ash.Info.Manifest.Field{}` is a *client-facing* description. It carries a
  resolved `%Ash.Info.Manifest.Type{}` and `has_default?`, where this library's
  readers return `%Ash.Resource.Attribute{}` and its callers read `.type`,
  `.constraints` and `.default` — `AshIntrospection.Codegen.ActionIntrospection`
  pattern-matches the struct itself
  (`lib/ash_introspection/codegen/action_introspection.ex:225`), and
  `AshIntrospection.Codegen.ValidationErrorTypes.classify_action_input_errors/3`
  hands it back to the caller. Rebuilding one from a manifest field would be
  lossy — `default` is not on the manifest at all — and would change a return
  type consumers already depend on.

  So the decorator captures the live struct. What it *computes* is the data
  that is genuinely derived and genuinely repeated per request: resolved
  aggregate types, the bulk-authorization strategy, client-facing field names
  under each built-in formatter and their reverse, and an entrypoint lookup
  keyed by client-facing name.

  Changing those return types is a separate, breaking decision. It belongs to
  the stage that deletes `AshIntrospection.Codegen.TypeDiscovery`, not to this
  additive one. See `docs/decisions.md`.

  ## What is written where

  | Struct | Payload |
  |---|---|
  | `%Ash.Info.Manifest{}` | `entrypoint_lookup` |
  | each `%Manifest.Resource{}` | fields, actions, aggregate types, bulk strategy, field names |
  | each `%Manifest.Relationship{}` on it | the read action it loads through, and how that action paginates |
  | each embedded `%Manifest.Type{}`'s nested resource | the same resource payload |
  | each `%Manifest.Type{}` with a field-names callback | field-name mappings |
  | each `%Manifest.Entrypoint{}` | `client_name`, from the `:entrypoint_name` callback |

  ## Decoration depends on compile order, and says so

  Every payload is read off a module atom the manifest names, so that module
  has to be compiled when `decorate/3` runs. Under parallel compilation it may
  not be. Rather than write wrong data, this module **skips** a module it
  cannot load — `Code.ensure_loaded?/1` guards every such read, the repo-wide
  rule from #49 — and the reader falls back to live `Ash.Resource.Info` for
  anything undecorated. That is safe but silent, which is exactly the staleness
  trap issue #23 records against a naive port of upstream's `8c07331`.

  **The caller owns the compile edges.** The transformer that calls this
  function must force every referenced module to compile first, and must give
  the manifest module a compile-time dependency on the domains it was built
  from. Neither belongs here; both are stage 3 of #23. Nothing in this module
  makes them harder — `decorate/3` is a pure function of its arguments.

  ## Namespace

  `decorate/3` takes the namespace as an argument rather than hard-coding one,
  because whether generators share `:ash_introspection` or each decorate under
  their own key is still open on #23. `AshIntrospection.Manifest.Custom`
  defaults to `:ash_introspection` and so does this module.
  """

  alias Ash.Info.Manifest
  alias AshIntrospection.FieldFormatter
  alias AshIntrospection.Manifest.Custom
  alias AshIntrospection.ResourceInfo
  alias AshIntrospection.TypeSystem.Introspection

  @builtin_formatters [:camel_case, :pascal_case, :snake_case]

  @typedoc """
  The slice of the pipeline/codegen config map the decorator reads.

  These are the callbacks the consumer already threads through
  `AshIntrospection.Rpc.Pipeline`; the decorator calls each once per field at
  compile time instead of once per field per request.
  """
  @type config :: %{
          optional(:format_field_for_client) => (atom(), module() | nil, atom() -> String.t()),
          optional(:get_original_field_name) => (module(), String.t() -> atom() | nil),
          optional(:entrypoint_name) => (module(), atom() -> String.t() | nil),
          optional(:field_names_callback) => atom(),
          optional(:output_field_formatter) => atom()
        }

  @doc """
  Returns `manifest` with `custom[namespace]` populated on every struct this
  library reads.

  Pure: same manifest and config in, same manifest out. Call it once, at
  compile time, on the result of `Ash.Info.Manifest.generate/1`.

  `config` is the pipeline config map. Every key is optional; with an empty map
  the decorator computes client names with
  `AshIntrospection.FieldFormatter.format_field_name/2`, which is what the
  pipeline does when the consumer supplies no callback.
  """
  @spec decorate(Manifest.t(), atom(), config()) :: Manifest.t()
  def decorate(manifest, namespace \\ Custom.default_namespace(), config \\ %{})

  def decorate(%Manifest{} = manifest, namespace, config) when is_atom(namespace) do
    decorated_entrypoints =
      Enum.map(manifest.entrypoints, &decorate_entrypoint(&1, namespace, config))

    %Manifest{
      manifest
      | resources: Enum.map(manifest.resources, &decorate_resource(&1, namespace, config)),
        types: Enum.map(manifest.types, &decorate_type(&1, namespace, config)),
        entrypoints: decorated_entrypoints,
        custom:
          put_namespace(manifest.custom, namespace, %{
            entrypoint_lookup: build_entrypoint_lookup(decorated_entrypoints, namespace)
          })
    }
  end

  # ---------------------------------------------------------------------------
  # Resources
  # ---------------------------------------------------------------------------

  defp decorate_resource(%Manifest.Resource{module: module} = resource, namespace, config) do
    case build_resource_payload(module, resource, config) do
      nil ->
        resource

      payload ->
        %Manifest.Resource{
          resource
          | custom: put_namespace(resource.custom, namespace, payload),
            relationships: decorate_relationships(module, resource.relationships, namespace)
        }
    end
  end

  # The pagination question a relationship query envelope asks (#24) is fixed
  # at compile time: it walks the relationship's `read_action`, or the
  # destination's primary read, and reads that action's `pagination`.
  # `AshIntrospection.ResourceInfo` owns that walk, so the decorator asks it
  # with an empty config and stores the live answer rather than repeating the
  # logic here.
  defp decorate_relationships(module, relationships, namespace) when is_map(relationships) do
    Map.new(relationships, fn {name, %Manifest.Relationship{} = relationship} ->
      payload = %{
        pagination: ResourceInfo.relationship_pagination(module, name),
        read_action: ResourceInfo.relationship_read_action(module, name)
      }

      {name,
       %Manifest.Relationship{
         relationship
         | custom: put_namespace(relationship.custom, namespace, payload)
       }}
    end)
  end

  defp decorate_relationships(_module, relationships, _namespace), do: relationships

  defp build_resource_payload(module, %Manifest.Resource{} = resource, config)
       when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and Ash.Resource.Info.resource?(module) do
      attributes = Ash.Resource.Info.attributes(module)
      calculations = Ash.Resource.Info.calculations(module)
      aggregates = Ash.Resource.Info.aggregates(module)
      actions = Ash.Resource.Info.actions(module)
      formatted = formatted_field_names(module, resource, config)

      %{
        attributes: attributes,
        public_attributes: Enum.filter(attributes, & &1.public?),
        public_calculations: Enum.filter(calculations, & &1.public?),
        public_aggregates: Enum.filter(aggregates, & &1.public?),
        actions: actions,
        by_name: %{
          attributes: by_name(attributes),
          calculations: by_name(calculations),
          aggregates: by_name(aggregates),
          actions: by_name(actions)
        },
        aggregate_types: aggregate_types(module, aggregates),
        authorize_bulk_strategy: authorize_bulk_strategy(module),
        field_name_mappings: field_name_mappings(formatted, config),
        reverse_field_name_mappings: reverse_field_name_mappings(module, formatted, config),
        formatted_field_names: formatted
      }
    end
  end

  defp build_resource_payload(_module, _resource, _config), do: nil

  # Both key forms, mirroring the `:attributes_by_name` and
  # `:calculations_by_name` maps Ash persists
  # (`deps/ash/lib/ash/resource/transformers/attributes_by_name.ex:19`), so a
  # string name reads the same here as it does through `Ash.Resource.Info`.
  defp by_name(entities) do
    Enum.reduce(entities, %{}, fn %{name: name} = entity, acc ->
      acc |> Map.put(name, entity) |> Map.put(to_string(name), entity)
    end)
  end

  # `Ash.Resource.Info.aggregate_type/2` walks the relationship path to the
  # aggregated field on every call, and the pipeline calls it per aggregate per
  # record. The answer is fixed at compile time. Its `{:ok, type}` /
  # `{:error, reason}` shape is preserved, because every caller here passes it
  # through untouched.
  defp aggregate_types(module, aggregates) do
    Map.new(aggregates, fn aggregate ->
      {aggregate.name, Ash.Resource.Info.aggregate_type(module, aggregate)}
    end)
  end

  # `AshIntrospection.Rpc.Pipeline` asks the data layer this per bulk
  # update/destroy request. A data layer cannot change between requests.
  defp authorize_bulk_strategy(module) do
    if Ash.DataLayer.data_layer_can?(module, :expr_error), do: :error, else: :filter
  end

  # ---------------------------------------------------------------------------
  # Field names
  # ---------------------------------------------------------------------------

  # One entry per field per built-in formatter. A `{module, function}` formatter
  # is consumer-supplied and chosen per request, so it stays live; the three
  # built-ins are the ones the pipeline actually spends its time on.
  defp formatted_field_names(module, %Manifest.Resource{} = resource, config) do
    for field <- field_atoms(module, resource),
        formatter <- @builtin_formatters,
        into: %{} do
      {{field, formatter}, format_for_client(field, module, formatter, config)}
    end
  end

  defp field_atoms(module, %Manifest.Resource{fields: fields, relationships: rels}) do
    live =
      Enum.map(Ash.Resource.Info.attributes(module), & &1.name) ++
        Enum.map(Ash.Resource.Info.calculations(module), & &1.name) ++
        Enum.map(Ash.Resource.Info.aggregates(module), & &1.name) ++
        Enum.map(Ash.Resource.Info.relationships(module), & &1.name)

    Enum.uniq(live ++ Map.keys(fields) ++ Map.keys(rels))
  end

  # The canonical client-facing name: the one the consumer's output formatter
  # produces. `reverse_field_name_mappings/3` accepts every built-in spelling,
  # because a client name arrives as a bare string with no formatter attached.
  defp field_name_mappings(formatted, config) do
    formatter = Map.get(config, :output_field_formatter, :camel_case)

    for {{field, ^formatter}, client_name} <- formatted, into: %{} do
      {field, client_name}
    end
  end

  # Built in a fixed formatter order and first-binding-wins, so two fields whose
  # client names collide under different formatters resolve the same way on
  # every compile. `:get_original_field_name` overrides the computed inverse
  # where the consumer supplies it, since that callback is the consumer's own
  # answer to this exact question.
  defp reverse_field_name_mappings(module, formatted, config) do
    computed =
      for formatter <- @builtin_formatters,
          {{field, ^formatter}, client_name} <- formatted,
          reduce: %{} do
        acc -> Map.put_new(acc, client_name, field)
      end

    case Map.get(config, :get_original_field_name) do
      callback when is_function(callback, 2) ->
        Enum.reduce(Map.keys(computed), computed, fn client_name, acc ->
          case callback.(module, client_name) do
            original when is_atom(original) and not is_nil(original) ->
              Map.put(acc, client_name, original)

            _ ->
              acc
          end
        end)

      _ ->
        computed
    end
  end

  # Mirrors `AshIntrospection.Rpc.ValueFormatter.format_field_for_client/4`.
  defp format_for_client(field, module, formatter, config) do
    case Map.get(config, :format_field_for_client) do
      callback when is_function(callback, 3) -> callback.(field, module, formatter)
      _ -> FieldFormatter.format_field_name(field, formatter)
    end
  end

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  # An embedded resource is a type carrying a resource, so its payload is the
  # resource payload — `Ash.Info.Manifest.Generator` files embedded resources
  # under `types` with `kind: :embedded_resource`, never under `resources`
  # (`deps/ash/lib/ash/info/manifest/generator.ex:110`).
  defp decorate_type(
         %Manifest.Type{kind: :embedded_resource, resource: %Manifest.Resource{} = nested} = type,
         namespace,
         config
       ) do
    %Manifest.Type{type | resource: decorate_resource(nested, namespace, config)}
  end

  defp decorate_type(%Manifest.Type{} = type, namespace, config) do
    case build_type_payload(type, config) do
      nil -> type
      payload -> %Manifest.Type{type | custom: put_namespace(type.custom, namespace, payload)}
    end
  end

  # Only a type that pins its own client field names is worth decorating. Every
  # other type's names come from the formatter, which needs no per-type map.
  defp build_type_payload(%Manifest.Type{} = type, config) do
    module = Manifest.Type.effective_module(type)
    callback = Map.get(config, :field_names_callback, :interop_field_names)

    if Introspection.has_field_names_callback?(module, callback) do
      mappings = Introspection.get_field_names_map(module, callback)

      %{
        field_name_mappings: mappings,
        reverse_field_name_mappings: Map.new(mappings, fn {field, name} -> {name, field} end)
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Entrypoints
  # ---------------------------------------------------------------------------

  defp decorate_entrypoint(%Manifest.Entrypoint{} = entrypoint, namespace, config) do
    payload = %{client_name: entrypoint_client_name(entrypoint, config)}

    %Manifest.Entrypoint{
      entrypoint
      | custom: put_namespace(entrypoint.custom, namespace, payload)
    }
  end

  # A client-facing action name is the consumer's DSL's business, and this
  # library has no DSL — the recorded reason #26 was declined. So there is no
  # default: without `:entrypoint_name` no entrypoint has a client name, and
  # the lookup is empty. An action name is not a usable default, because it is
  # unique per resource and the lookup is global: `:read` names one entrypoint
  # on every resource in the app.
  defp entrypoint_client_name(%Manifest.Entrypoint{resource: resource, action: action}, config) do
    case Map.get(config, :entrypoint_name) do
      callback when is_function(callback, 2) ->
        case callback.(resource, action.name) do
          name when is_binary(name) -> name
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # The O(1) lookup that replaces a scan over every entrypoint in the
  # application, once per request. An entrypoint whose client name is `nil` is
  # left out: the consumer said it has no client-facing name.
  defp build_entrypoint_lookup(entrypoints, namespace) do
    Enum.reduce(entrypoints, %{}, fn entrypoint, acc ->
      case Custom.entrypoint_client_name(entrypoint, namespace) do
        name when is_binary(name) -> put_entrypoint(acc, name, entrypoint)
        _ -> acc
      end
    end)
  end

  # Two entrypoints answering to one client name is a request the runtime
  # cannot route, and silently keeping one of them would send half the calls to
  # the wrong action. Fail the compile instead, naming both.
  defp put_entrypoint(acc, name, entrypoint) do
    case Map.get(acc, name) do
      nil ->
        Map.put(acc, name, entrypoint)

      %Manifest.Entrypoint{} = existing ->
        raise ArgumentError, """
        Two entrypoints claim the client-facing name #{inspect(name)}:

          #{inspect(existing.resource)}.#{existing.action.name}
          #{inspect(entrypoint.resource)}.#{entrypoint.action.name}

        The `:entrypoint_name` callback must return a name that is unique
        across the whole manifest — the lookup is global, not per resource.
        """
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp put_namespace(custom, namespace, payload) when is_map(custom),
    do: Map.put(custom, namespace, payload)

  defp put_namespace(_custom, namespace, payload), do: %{namespace => payload}
end
