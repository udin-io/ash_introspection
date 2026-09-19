# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Manifest.Custom do
  @moduledoc """
  Reads the data `AshIntrospection.Manifest.Decorator` wrote under
  `custom.<namespace>`.

  `Ash.Info.Manifest` leaves a `custom` map on every struct it builds so a
  client library can hang its own precomputed data off the manifest. This
  module is the only place in `lib/` that reads it, and
  `AshIntrospection.Manifest.Decorator` is the only place that writes it.
  Nothing else pattern-matches `:custom` directly.

  ## The namespace is a parameter, not a constant

  Every function takes a trailing `namespace` defaulting to
  `:ash_introspection`. Whether one shared decoration serves every generator
  built on this core, or each generator decorates under its own key, is an
  open question on issue #23 that this stage does not settle — so the code
  answers both. See `docs/decisions.md`.

  ## Absent decoration is not an empty decoration

  `decorated?/2` is the question every caller asks first.
  `AshIntrospection.ResourceInfo` reads a decorated resource and falls back to
  live `Ash.Resource.Info` for an undecorated one, so the two cases have to be
  distinguishable: a resource whose decoration is missing is not a resource
  with no attributes. Singular readers below return `nil` for "no such field"
  only after `decorated?/2` has answered `true`.
  """

  alias Ash.Info.Manifest

  @default_namespace :ash_introspection

  @typedoc """
  The decoration map written on a `%Ash.Info.Manifest.Resource{}`.

  Attribute, calculation, aggregate and action entries are the live Ash
  structs, captured at decoration time. See the decorator's moduledoc for why
  they are not rebuilt from `%Ash.Info.Manifest.Field{}`. Relationships are the
  exception: they are narrowed to `t:relationship_record/0`, because every call
  site reads two keys off one.
  """
  @type resource_payload :: %{
          attributes: [Ash.Resource.Attribute.t()],
          public_attributes: [Ash.Resource.Attribute.t()],
          public_calculations: [Ash.Resource.Calculation.t()],
          public_aggregates: [Ash.Resource.Aggregate.t()],
          actions: [Ash.Resource.Actions.action()],
          by_name: %{atom() => %{(atom() | String.t()) => struct() | relationship_record()}},
          aggregate_types: %{atom() => term()},
          return_classifications: %{atom() => term()},
          authorize_bulk_strategy: :error | :filter,
          field_name_mappings: %{atom() => String.t()},
          reverse_field_name_mappings: %{String.t() => atom()},
          formatted_field_names: %{{atom(), atom()} => String.t()},
          argument_name_mappings: %{atom() => %{atom() => String.t()}},
          reverse_argument_name_mappings: %{atom() => %{String.t() => atom()}},
          formatted_argument_names: %{atom() => %{{atom(), atom()} => String.t()}}
        }

  @typedoc """
  One relationship, narrowed to what the request path reads off one.

  `AshIntrospection.ResourceInfo.relationship/3` narrows it once more, dropping
  `public?` — that key is here so `public_relationship/3` has something to
  filter on.
  """
  @type relationship_record :: %{
          name: atom(),
          destination: module(),
          cardinality: :one | :many,
          public?: boolean()
        }

  @typedoc "The decoration map written on a `%Ash.Info.Manifest.Relationship{}`."
  @type relationship_payload :: %{
          pagination: :offset | :keyset | :mixed | :none,
          read_action: atom() | nil
        }

  @typedoc "The decoration map written on a `%Ash.Info.Manifest.Type{}`."
  @type type_payload :: %{
          field_name_mappings: %{atom() => String.t()},
          reverse_field_name_mappings: %{String.t() => atom()}
        }

  @typedoc "The decoration map written on a `%Ash.Info.Manifest.Entrypoint{}`."
  @type entrypoint_payload :: %{client_name: String.t() | nil}

  @typedoc "The decoration map written on the `%Ash.Info.Manifest{}` itself."
  @type manifest_payload :: %{entrypoint_lookup: %{String.t() => Manifest.Entrypoint.t()}}

  @doc "The namespace used when a caller names none."
  @spec default_namespace() :: atom()
  def default_namespace, do: @default_namespace

  # ---------------------------------------------------------------------------
  # Generic
  # ---------------------------------------------------------------------------

  @doc """
  The decoration map on any struct that carries a `custom` field, or `nil`.

  Works for `%Ash.Info.Manifest{}`, `%Manifest.Resource{}`, `%Manifest.Type{}`,
  `%Manifest.Entrypoint{}` and `%Manifest.Action{}` alike — they all carry the
  same `custom: %{}` field.
  """
  @spec payload(struct() | nil, atom()) :: map() | nil
  def payload(struct, namespace \\ @default_namespace)

  def payload(%{custom: custom}, namespace) when is_map(custom),
    do: Map.get(custom, namespace)

  def payload(_, _), do: nil

  @doc """
  Has `struct` been decorated under `namespace`?

  Ask this before reading anything else. A `false` answer means the caller must
  read live, not that the decorated value is empty.
  """
  @spec decorated?(struct() | nil, atom()) :: boolean()
  def decorated?(struct, namespace \\ @default_namespace),
    do: is_map(payload(struct, namespace))

  # ---------------------------------------------------------------------------
  # Resource fields
  # ---------------------------------------------------------------------------

  @doc "Every attribute, public and private, in `Ash.Resource.Info.attributes/1` order."
  @spec attributes(Manifest.Resource.t() | nil, atom()) :: [Ash.Resource.Attribute.t()]
  def attributes(resource, namespace \\ @default_namespace),
    do: list(resource, namespace, :attributes)

  @doc "The public attributes, in `Ash.Resource.Info.public_attributes/1` order."
  @spec public_attributes(Manifest.Resource.t() | nil, atom()) :: [Ash.Resource.Attribute.t()]
  def public_attributes(resource, namespace \\ @default_namespace),
    do: list(resource, namespace, :public_attributes)

  @doc "The public calculations, in `Ash.Resource.Info.public_calculations/1` order."
  @spec public_calculations(Manifest.Resource.t() | nil, atom()) :: [Ash.Resource.Calculation.t()]
  def public_calculations(resource, namespace \\ @default_namespace),
    do: list(resource, namespace, :public_calculations)

  @doc "The public aggregates, in `Ash.Resource.Info.public_aggregates/1` order."
  @spec public_aggregates(Manifest.Resource.t() | nil, atom()) :: [Ash.Resource.Aggregate.t()]
  def public_aggregates(resource, namespace \\ @default_namespace),
    do: list(resource, namespace, :public_aggregates)

  @doc "Every action, in `Ash.Resource.Info.actions/1` order."
  @spec actions(Manifest.Resource.t() | nil, atom()) :: [Ash.Resource.Actions.action()]
  def actions(resource, namespace \\ @default_namespace),
    do: list(resource, namespace, :actions)

  @doc """
  The attribute named `name`, or `nil`.

  `name` may be an atom or a string, matching `Ash.Resource.Info.attribute/2`,
  which reads a persisted map carrying both key forms.
  """
  @spec attribute(Manifest.Resource.t() | nil, atom() | String.t(), atom()) ::
          Ash.Resource.Attribute.t() | nil
  def attribute(resource, name, namespace \\ @default_namespace),
    do: by_name(resource, namespace, :attributes, name)

  @doc "The attribute named `name` if it is public, or `nil`."
  @spec public_attribute(Manifest.Resource.t() | nil, atom() | String.t(), atom()) ::
          Ash.Resource.Attribute.t() | nil
  def public_attribute(resource, name, namespace \\ @default_namespace),
    do: only_public(attribute(resource, name, namespace))

  @doc "The calculation named `name`, or `nil`."
  @spec calculation(Manifest.Resource.t() | nil, atom() | String.t(), atom()) ::
          Ash.Resource.Calculation.t() | nil
  def calculation(resource, name, namespace \\ @default_namespace),
    do: by_name(resource, namespace, :calculations, name)

  @doc "The calculation named `name` if it is public, or `nil`."
  @spec public_calculation(Manifest.Resource.t() | nil, atom() | String.t(), atom()) ::
          Ash.Resource.Calculation.t() | nil
  def public_calculation(resource, name, namespace \\ @default_namespace),
    do: only_public(calculation(resource, name, namespace))

  @doc "The aggregate named `name`, or `nil`."
  @spec aggregate(Manifest.Resource.t() | nil, atom() | String.t(), atom()) ::
          Ash.Resource.Aggregate.t() | nil
  def aggregate(resource, name, namespace \\ @default_namespace),
    do: by_name(resource, namespace, :aggregates, name)

  @doc "The aggregate named `name` if it is public, or `nil`."
  @spec public_aggregate(Manifest.Resource.t() | nil, atom() | String.t(), atom()) ::
          Ash.Resource.Aggregate.t() | nil
  def public_aggregate(resource, name, namespace \\ @default_namespace),
    do: only_public(aggregate(resource, name, namespace))

  @doc "The action named `name`, or `nil`."
  @spec action(Manifest.Resource.t() | nil, atom(), atom()) ::
          Ash.Resource.Actions.action() | nil
  def action(resource, name, namespace \\ @default_namespace),
    do: by_name(resource, namespace, :actions, name)

  @doc """
  The resolved type of `aggregate`, precomputed.

  `Ash.Resource.Info.aggregate_type/2` resolves the aggregate's field type
  through the relationship path on every call; the decorator does it once. The
  return shape is that function's — an `{:ok, type}` or `{:error, reason}`
  tuple — because every caller here passes it straight through.

  Returns `:undecorated` when the aggregate has no precomputed entry, which is
  the caller's signal to resolve live. `nil` is not usable as that signal: it
  is a legitimate resolved value.
  """
  @spec aggregate_type(Manifest.Resource.t() | nil, Ash.Resource.Aggregate.t() | atom(), atom()) ::
          term() | :undecorated
  def aggregate_type(resource, aggregate, namespace \\ @default_namespace)

  def aggregate_type(resource, %{name: name}, namespace),
    do: aggregate_type(resource, name, namespace)

  def aggregate_type(resource, name, namespace) when is_atom(name) do
    case payload(resource, namespace) do
      %{aggregate_types: types} -> Map.get(types, name, :undecorated)
      _ -> :undecorated
    end
  end

  def aggregate_type(_resource, _aggregate, _namespace), do: :undecorated

  @doc """
  The precomputed return classification of `action`, or `:undecorated`.

  The shape is
  `AshIntrospection.Codegen.ActionIntrospection.action_returns_field_selectable_type?/2`'s
  — an `{:ok, kind, data}` or `{:error, reason}` tuple — because every
  caller passes it through untouched. `:undecorated` is the signal to compute
  live; `{:error, _}` cannot double as it, being a legitimate classification.

  The classification is scoped by the manifest that was decorated:
  `classify_return_type/3` asks whether the struct an action returns is a
  declared resource, and a manifest is what declares one. Decorating settles
  that question at compile time rather than changing it.
  """
  @spec return_classification(
          Manifest.Resource.t() | nil,
          Ash.Resource.Actions.action() | atom(),
          atom()
        ) :: term() | :undecorated
  def return_classification(resource, action, namespace \\ @default_namespace)

  def return_classification(resource, %{name: name}, namespace),
    do: return_classification(resource, name, namespace)

  def return_classification(resource, name, namespace) when is_atom(name) do
    case payload(resource, namespace) do
      %{return_classifications: classifications} -> Map.get(classifications, name, :undecorated)
      _ -> :undecorated
    end
  end

  def return_classification(_resource, _action, _namespace), do: :undecorated

  @doc """
  The precomputed bulk-authorization strategy, `:error` or `:filter`.

  `Ash.DataLayer.data_layer_can?(resource, :expr_error)` is fixed at compile
  time, so the pipeline need not ask per request. `nil` when undecorated.
  """
  @spec authorize_bulk_strategy(Manifest.Resource.t() | nil, atom()) :: :error | :filter | nil
  def authorize_bulk_strategy(resource, namespace \\ @default_namespace) do
    case payload(resource, namespace) do
      %{authorize_bulk_strategy: strategy} -> strategy
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Field names
  # ---------------------------------------------------------------------------

  @doc "The `%{field_atom => client_name}` map for a decorated resource, or `%{}`."
  @spec field_name_mappings(Manifest.Resource.t() | Manifest.Type.t() | nil, atom()) ::
          %{atom() => String.t()}
  def field_name_mappings(struct, namespace \\ @default_namespace) do
    case payload(struct, namespace) do
      %{field_name_mappings: mappings} -> mappings
      _ -> %{}
    end
  end

  @doc "The `%{client_name => field_atom}` map for a decorated resource, or `%{}`."
  @spec reverse_field_name_mappings(Manifest.Resource.t() | Manifest.Type.t() | nil, atom()) ::
          %{String.t() => atom()}
  def reverse_field_name_mappings(struct, namespace \\ @default_namespace) do
    case payload(struct, namespace) do
      %{reverse_field_name_mappings: mappings} -> mappings
      _ -> %{}
    end
  end

  @doc "The client-facing name for `field`, or `nil` when it has no mapping."
  @spec mapped_field_name(Manifest.Resource.t() | Manifest.Type.t() | nil, atom(), atom()) ::
          String.t() | nil
  def mapped_field_name(struct, field, namespace \\ @default_namespace) when is_atom(field),
    do: struct |> field_name_mappings(namespace) |> Map.get(field)

  @doc """
  The field atom behind a client-facing name, or `nil`.

  This is the reverse of the consumer's `:format_field_for_client` callback,
  computed once per field at decoration time instead of per request.
  """
  @spec original_field_name(
          Manifest.Resource.t() | Manifest.Type.t() | nil,
          String.t() | atom(),
          atom()
        ) :: atom() | nil
  def original_field_name(struct, client_name, namespace \\ @default_namespace)

  def original_field_name(struct, client_name, namespace) when is_binary(client_name),
    do: struct |> reverse_field_name_mappings(namespace) |> Map.get(client_name)

  def original_field_name(struct, client_name, namespace) when is_atom(client_name),
    do: original_field_name(struct, Atom.to_string(client_name), namespace)

  def original_field_name(_struct, _client_name, _namespace), do: nil

  @doc """
  The precomputed client-facing name for `field` under `formatter`, or `nil`.

  Only the built-in formatters are precomputed — `:camel_case`,
  `:pascal_case`, `:snake_case`. A `{module, function}` formatter is
  consumer-supplied and runtime-configurable, so it is computed live.
  """
  @spec formatted_field_name(Manifest.Resource.t() | nil, atom(), atom(), atom()) ::
          String.t() | nil
  def formatted_field_name(resource, field, formatter, namespace \\ @default_namespace)

  def formatted_field_name(resource, field, formatter, namespace)
      when is_atom(field) and is_atom(formatter) do
    case payload(resource, namespace) do
      %{formatted_field_names: names} -> Map.get(names, {field, formatter})
      _ -> nil
    end
  end

  def formatted_field_name(_resource, _field, _formatter, _namespace), do: nil

  # ---------------------------------------------------------------------------
  # Argument names
  #
  # The same three maps the fields have, one set per action, because an
  # argument name is unique within an action and not across a resource: two
  # actions may each take a `:filter`, and they are different arguments.
  # ---------------------------------------------------------------------------

  @doc "The `%{argument_atom => client_name}` map for one action, or `%{}`."
  @spec argument_name_mappings(Manifest.Resource.t() | nil, atom(), atom()) ::
          %{atom() => String.t()}
  def argument_name_mappings(resource, action_name, namespace \\ @default_namespace)

  def argument_name_mappings(resource, action_name, namespace) when is_atom(action_name) do
    case payload(resource, namespace) do
      %{argument_name_mappings: by_action} -> Map.get(by_action, action_name, %{})
      _ -> %{}
    end
  end

  def argument_name_mappings(_resource, _action_name, _namespace), do: %{}

  @doc "The `%{client_name => argument_atom}` map for one action, or `%{}`."
  @spec reverse_argument_name_mappings(Manifest.Resource.t() | nil, atom(), atom()) ::
          %{String.t() => atom()}
  def reverse_argument_name_mappings(resource, action_name, namespace \\ @default_namespace)

  def reverse_argument_name_mappings(resource, action_name, namespace)
      when is_atom(action_name) do
    case payload(resource, namespace) do
      %{reverse_argument_name_mappings: by_action} -> Map.get(by_action, action_name, %{})
      _ -> %{}
    end
  end

  def reverse_argument_name_mappings(_resource, _action_name, _namespace), do: %{}

  @doc "The client-facing name for one argument of one action, or `nil`."
  @spec mapped_argument_name(Manifest.Resource.t() | nil, atom(), atom(), atom()) ::
          String.t() | nil
  def mapped_argument_name(resource, action_name, argument, namespace \\ @default_namespace)
      when is_atom(argument) do
    resource |> argument_name_mappings(action_name, namespace) |> Map.get(argument)
  end

  @doc "The argument atom behind a client-facing name on one action, or `nil`."
  @spec original_argument_name(
          Manifest.Resource.t() | nil,
          atom(),
          String.t() | atom(),
          atom()
        ) :: atom() | nil
  def original_argument_name(resource, action_name, client_name, namespace \\ @default_namespace)

  def original_argument_name(resource, action_name, client_name, namespace)
      when is_binary(client_name) do
    resource |> reverse_argument_name_mappings(action_name, namespace) |> Map.get(client_name)
  end

  def original_argument_name(resource, action_name, client_name, namespace)
      when is_atom(client_name) and not is_nil(client_name) do
    original_argument_name(resource, action_name, Atom.to_string(client_name), namespace)
  end

  def original_argument_name(_resource, _action_name, _client_name, _namespace), do: nil

  @doc """
  The precomputed client-facing name for one argument under `formatter`, or
  `nil`.

  Only the built-in formatters are precomputed, for the reason
  `formatted_field_name/4` gives.
  """
  @spec formatted_argument_name(Manifest.Resource.t() | nil, atom(), atom(), atom(), atom()) ::
          String.t() | nil
  def formatted_argument_name(
        resource,
        action_name,
        argument,
        formatter,
        namespace \\ @default_namespace
      )

  def formatted_argument_name(resource, action_name, argument, formatter, namespace)
      when is_atom(action_name) and is_atom(argument) and is_atom(formatter) do
    case payload(resource, namespace) do
      %{formatted_argument_names: by_action} ->
        by_action |> Map.get(action_name, %{}) |> Map.get({argument, formatter})

      _ ->
        nil
    end
  end

  def formatted_argument_name(_resource, _action_name, _argument, _formatter, _namespace), do: nil

  # ---------------------------------------------------------------------------
  # Relationships
  #
  # The narrowed records are read off the **resource**, not off a
  # `%Manifest.Relationship{}`: a private relationship has no such struct in a
  # manifest built with the defaults, and it is exactly the case these records
  # exist to answer. The pagination readers below take the struct, because #24
  # asks that question only of a relationship a client can select.
  # ---------------------------------------------------------------------------

  @doc """
  The relationship named `name` on a decorated resource, or `nil`.

  Complete: the decorator lists relationships live, so a private relationship
  the manifest itself does not carry is here too. That is the point of storing
  them — `%Ash.Info.Manifest{}` records no build options, so a reader cannot
  tell a manifest built without private relationships from a resource that has
  none.

  `name` may be an atom or a string, like `attribute/3`. A `nil` means "no such
  relationship" for a decorated resource and "read live" for an undecorated one;
  `decorated?/2` separates the two.
  """
  @spec relationship(Manifest.Resource.t() | nil, atom() | String.t(), atom()) ::
          relationship_record() | nil
  def relationship(resource, name, namespace \\ @default_namespace),
    do: by_name(resource, namespace, :relationships, name)

  @doc """
  The relationship named `name` if it is public, or `nil`.

  Reads the stored `public?` flag rather than the manifest's own relationship
  map, which carries private relationships when the manifest was built with
  `include_private_relationships?: true`.
  """
  @spec public_relationship(Manifest.Resource.t() | nil, atom() | String.t(), atom()) ::
          relationship_record() | nil
  def public_relationship(resource, name, namespace \\ @default_namespace),
    do: only_public(relationship(resource, name, namespace))

  @doc """
  How the read behind a decorated `:many` relationship paginates.

  `:none` for an undecorated relationship, for every to-one relationship, and
  for a read that offers neither pagination kind. Those three collapse on
  purpose: a caller asking how to page a relationship it cannot page gets the
  same answer either way.
  """
  @spec relationship_pagination(Manifest.Relationship.t() | nil, atom()) ::
          :offset | :keyset | :mixed | :none
  def relationship_pagination(relationship, namespace \\ @default_namespace) do
    case payload(relationship, namespace) do
      %{pagination: pagination} -> pagination
      _ -> :none
    end
  end

  @doc """
  The read action a decorated `:many` relationship loads through, or `nil`.

  `nil` for an undecorated relationship and for a to-one one.
  """
  @spec relationship_read_action(Manifest.Relationship.t() | nil, atom()) :: atom() | nil
  def relationship_read_action(relationship, namespace \\ @default_namespace) do
    case payload(relationship, namespace) do
      %{read_action: read_action} -> read_action
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Entrypoints
  # ---------------------------------------------------------------------------

  @doc """
  The `%{client_name => %Ash.Info.Manifest.Entrypoint{}}` lookup, or `%{}`.

  One map read replaces a scan over every entrypoint in the application. The
  key is the client-facing name the consumer's `:entrypoint_name` callback
  returned, as a string.
  """
  @spec entrypoint_lookup(Ash.Info.Manifest.t() | nil, atom()) ::
          %{String.t() => Manifest.Entrypoint.t()}
  def entrypoint_lookup(manifest, namespace \\ @default_namespace) do
    case payload(manifest, namespace) do
      %{entrypoint_lookup: lookup} -> lookup
      _ -> %{}
    end
  end

  @doc "The entrypoint a client asked for by name, or `nil`."
  @spec entrypoint(Ash.Info.Manifest.t() | nil, String.t() | atom(), atom()) ::
          Manifest.Entrypoint.t() | nil
  def entrypoint(manifest, client_name, namespace \\ @default_namespace)

  def entrypoint(manifest, client_name, namespace) when is_binary(client_name),
    do: manifest |> entrypoint_lookup(namespace) |> Map.get(client_name)

  def entrypoint(manifest, client_name, namespace) when is_atom(client_name),
    do: entrypoint(manifest, Atom.to_string(client_name), namespace)

  def entrypoint(_manifest, _client_name, _namespace), do: nil

  @doc "The client-facing name decorated onto `entrypoint`, or `nil`."
  @spec entrypoint_client_name(Manifest.Entrypoint.t() | nil, atom()) :: String.t() | nil
  def entrypoint_client_name(entrypoint, namespace \\ @default_namespace) do
    case payload(entrypoint, namespace) do
      %{client_name: name} -> name
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp list(struct, namespace, key) do
    case payload(struct, namespace) do
      %{^key => entries} when is_list(entries) -> entries
      _ -> []
    end
  end

  defp by_name(struct, namespace, kind, name) when is_atom(name) or is_binary(name) do
    case payload(struct, namespace) do
      %{by_name: by_name} -> by_name |> Map.get(kind, %{}) |> Map.get(name)
      _ -> nil
    end
  end

  defp by_name(_struct, _namespace, _kind, _name), do: nil

  defp only_public(%{public?: true} = entity), do: entity
  defp only_public(_), do: nil
end
