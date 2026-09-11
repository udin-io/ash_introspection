# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.ResourceInfo do
  @moduledoc """
  The one place this library asks what a resource looks like.

  Every `Ash.Resource.Info` call in `lib/` goes through this module. That is
  the whole point of it: issue #23 replaces live introspection with the
  precomputed `Ash.Info.Manifest` upstream `ash_typescript` adopted, and a
  migration spread across 64 call sites in nine modules is not reviewable. One
  reader makes each later stage a small diff.

  ## Two sources, one contract

  Reads take the config map the pipeline and codegen already thread, and look
  for an optional `:manifest` key — the same shape `:load_restrictions` and
  `:is_interop_resource?` use.

  | Config | Source |
  |---|---|
  | no `:manifest` key, or `nil` | live `Ash.Resource.Info`, exactly as before |
  | `%Ash.Info.Manifest{}` | the manifest, lookups rebuilt per read |
  | `AshIntrospection.ResourceInfo.Source` | the manifest, lookups built once |

  **Omitting the key preserves current behaviour exactly.** That is the
  compatibility guarantee of this stage and the reason it is reversible: no
  caller in this repo passes `:manifest` yet, so every read is still live.
  `test/ash_introspection/resource_info_test.exs` proves it against
  `Ash.Resource.Info` directly rather than asserting it.

  ## `resource?/1` is two questions, not one

  `Ash.Resource.Info.resource?/1` answers a fact about a **module**.
  `Ash.Info.Manifest.has_resource?/2` answers a fact about the **declared API
  surface**. They are not the same question, and 18 of the 64 sites ask it, so
  this module refuses to guess which one a caller meant:

    * `runtime_resource?/2` — manifest first, live `Ash.Resource.Info` when
      the module is absent from it. For the request path, where the argument
      can be a runtime `value.__struct__` that Ash handed back. A module
      nobody declared must still serialize as a resource; answering `false`
      would silently drop it into the generic `Map.from_struct/1` branch.

    * `declared_resource?/2` — the manifest is the whole answer when one is
      present; absence means `false`. For codegen, where scoping *is* the
      point: a resource nobody exposed should not appear in generated output.

  Both count embedded resources. `Ash.Info.Manifest.Generator` splits them out
  of `resources` and re-enters them under `types` with
  `kind: :embedded_resource`, so a bare `has_resource?/2` would answer `false`
  for every embedded resource — a divergence from live introspection that has
  nothing to do with scoping. The only difference between the two functions is
  what a **missing** module means.

  Everything else defaults to the fallback reading. A site is given
  `declared_resource?/2` only when it is unambiguously codegen.

  ## What the manifest answers

  Every reader is manifest-backed, and they divide into two groups by *what
  the manifest has to carry* for them to be:

  | Function | Answered from |
  |---|---|
  | `runtime_resource?/2`, `declared_resource?/2`, `embedded?/2` | the manifest as ash generates it |
  | `primary_key/2`, `identity_keys/3` | the manifest as ash generates it |
  | `relationship/3`, `public_relationship/3` | the manifest as ash generates it |
  | `public_field_names/2` | the manifest as ash generates it |
  | every `attribute`, `calculation`, `aggregate`, `action` reader | `custom.<namespace>`, written by `AshIntrospection.Manifest.Decorator` |
  | `aggregate_type/3`, `authorize_bulk_strategy/2` | `custom.<namespace>` |

  The second group needs decoration because a generated manifest cannot answer
  it. `%Ash.Info.Manifest.Field{}` is a client-facing description: it carries a
  resolved `%Ash.Info.Manifest.Type{}` where callers here read
  `{type, constraints}`, and `has_default?` where they read `default`. The
  decorator captures the live struct once, at compile time, so the answer is
  identical rather than approximated. `test/ash_introspection/manifest/`
  proves that field for field.

  **A manifest is not a complete list of relationships.**
  `Ash.Info.Manifest.Generator.generate/1` defaults
  `:include_private_relationships?` to `false`, so `relationship/3` falls back
  to live on a miss — a private `belongs_to` is absent from the manifest and
  present in `Ash.Resource.Info`. `public_relationship/3` does not fall back:
  every public relationship is carried, so a miss there is the answer.

  **An undecorated manifest still reads live for the second group.** A
  resource the decorator skipped — a module it could not load at decoration
  time — is present in the manifest and bare, and is indistinguishable to
  these readers from a resource the manifest never carried. Both fall back.

  ## Shapes the two sources cannot share

  Where the native return values differ, this module returns a narrow map with
  only the keys its call sites read, and both sources build it. `relationship/3`
  is the case: live returns `%Ash.Resource.Relationships.HasOne{}` and friends,
  the manifest returns `%Ash.Info.Manifest.Relationship{}`. Callers here read
  `:destination` and `:cardinality` and nothing else, so that is what comes
  back. `identity_keys/3` is the same narrowing over `%Ash.Resource.Identity{}`
  versus the manifest's `%{keys: [...]}`.

  ## Not `:resource_info_module`

  The `:resource_info_module` config key names the **consumer's** generated
  Info module, used for `interop_resource?/1` and `get_original_field_name/2`.
  It is unrelated to this module and to `:manifest`.
  """

  alias AshIntrospection.Manifest.Custom
  alias AshIntrospection.ResourceInfo.Source

  @typedoc """
  The slice of the pipeline/codegen config map this module reads.

  Every other key is ignored.
  """
  @type config :: %{optional(:manifest) => Ash.Info.Manifest.t() | Source.t() | nil}

  @typedoc "A relationship narrowed to the keys this library reads."
  @type relationship :: %{name: atom(), destination: module(), cardinality: :one | :many}

  # ---------------------------------------------------------------------------
  # Source selection
  # ---------------------------------------------------------------------------

  @doc """
  Builds the lookup maps for a manifest once, so reads do not rebuild them.

  Accepts a `%Ash.Info.Manifest{}`, an already prepared
  `AshIntrospection.ResourceInfo.Source`, or `nil`. Returns `nil` unchanged, so
  it is safe to call on a config value that may be absent.

  `namespace` names the `custom` key `AshIntrospection.Manifest.Decorator`
  decorated under. `nil` keeps a prepared source's own namespace and gives a
  bare manifest the default.
  """
  @spec prepare(Ash.Info.Manifest.t() | Source.t() | nil, atom() | nil) :: Source.t() | nil
  def prepare(manifest, namespace \\ nil)
  def prepare(nil, _namespace), do: nil
  def prepare(manifest, namespace), do: Source.new(manifest, namespace)

  @doc """
  Normalizes the `:manifest` key on a config map with `prepare/2`.

  Call it once at an entry point rather than preparing on every read. A config
  with no `:manifest` key is returned untouched. An optional
  `:manifest_namespace` key names the decoration namespace.
  """
  @spec normalize_config(map()) :: map()
  def normalize_config(config) when is_map(config) do
    case Map.get(config, :manifest) do
      nil ->
        config

      manifest ->
        Map.put(config, :manifest, prepare(manifest, Map.get(config, :manifest_namespace)))
    end
  end

  @doc """
  The decorated `%Ash.Info.Manifest.Resource{}` for `resource` and the
  namespace it was decorated under, or `nil` to read live.

  For the modules that read decorated data this one does not wrap —
  `AshIntrospection.Codegen.ActionIntrospection` and its return
  classification. They still go through `AshIntrospection.Manifest.Custom` to
  read it; this only finds the struct.

  `nil` covers three cases a caller treats identically: no manifest, a manifest
  that does not carry the module, and a manifest that carries it undecorated.
  """
  @spec decoration(module(), config()) :: {Ash.Info.Manifest.Resource.t(), atom()} | nil
  def decoration(resource, config \\ %{}), do: decorated(config, resource)

  @doc """
  Returns the prepared manifest source on `config`, or `nil` for live reads.
  """
  @spec source(config()) :: Source.t() | nil
  def source(config) when is_map(config),
    do: prepare(Map.get(config, :manifest), Map.get(config, :manifest_namespace))

  def source(_), do: nil

  # ---------------------------------------------------------------------------
  # Classification
  # ---------------------------------------------------------------------------

  @doc """
  Is `module` a resource, falling back to live introspection when the manifest
  does not know it?

  For the request path. See the module doc for why this is not the same
  question as `declared_resource?/2`.
  """
  @spec runtime_resource?(term(), config()) :: boolean()
  def runtime_resource?(module, config \\ %{})

  def runtime_resource?(module, config) when is_atom(module) and not is_nil(module) do
    case source(config) do
      nil -> Ash.Resource.Info.resource?(module)
      source -> known_resource?(source, module) or Ash.Resource.Info.resource?(module)
    end
  end

  def runtime_resource?(_module, _config), do: false

  @doc """
  Is `module` part of the declared API surface?

  With a manifest, absence is the answer: a module nobody exposed is not a
  resource here. Without one, this is `Ash.Resource.Info.resource?/1`. For
  codegen only.
  """
  @spec declared_resource?(term(), config()) :: boolean()
  def declared_resource?(module, config \\ %{})

  def declared_resource?(module, config) when is_atom(module) and not is_nil(module) do
    case source(config) do
      nil -> Ash.Resource.Info.resource?(module)
      source -> known_resource?(source, module)
    end
  end

  def declared_resource?(_module, _config), do: false

  @doc """
  Is `module` an embedded resource?

  Manifest first, live when the module is absent from it — embedded resources
  live in `manifest.types` with `kind: :embedded_resource`, not in
  `manifest.resources`.
  """
  @spec embedded?(term(), config()) :: boolean()
  def embedded?(module, config \\ %{})

  def embedded?(module, config) when is_atom(module) and not is_nil(module) do
    case source(config) do
      nil ->
        Ash.Resource.Info.embedded?(module)

      source ->
        cond do
          embedded_type?(source, module) -> true
          Map.has_key?(source.resources, module) -> false
          true -> Ash.Resource.Info.embedded?(module)
        end
    end
  end

  def embedded?(_module, _config), do: false

  # ---------------------------------------------------------------------------
  # Resource shape
  # ---------------------------------------------------------------------------

  @doc """
  The primary key field names of `resource`.

  Returns `[]` for a module the manifest does not carry, matching
  `Ash.Info.Manifest.primary_key/2`.
  """
  @spec primary_key(module(), config()) :: [atom()]
  def primary_key(resource, config \\ %{}) do
    case manifest_resource(config, resource) do
      nil -> Ash.Resource.Info.primary_key(resource)
      %{primary_key: primary_key} -> primary_key || []
    end
  end

  @doc """
  The key names of the identity `identity_name` on `resource`, or `nil`.

  A narrowing: live introspection returns `%Ash.Resource.Identity{}` and the
  manifest returns `%{keys: [...]}`. Every caller here reads `:keys`.
  """
  @spec identity_keys(module(), atom(), config()) :: [atom()] | nil
  def identity_keys(resource, identity_name, config \\ %{}) do
    case manifest_resource(config, resource) do
      nil ->
        case Ash.Resource.Info.identity(resource, identity_name) do
          nil -> nil
          identity -> identity.keys
        end

      manifest_resource ->
        case Ash.Info.Manifest.Resource.get_identity(manifest_resource, identity_name) do
          nil -> nil
          %{keys: keys} -> keys
        end
    end
  end

  @doc """
  The names of every public field on `resource` — attributes, calculations and
  aggregates together.

  One `Map.keys/1` on the manifest path; three list walks on the live one.
  """
  @spec public_field_names(module(), config()) :: [atom()]
  def public_field_names(resource, config \\ %{}) do
    case manifest_resource(config, resource) do
      nil ->
        Enum.map(Ash.Resource.Info.public_attributes(resource), & &1.name) ++
          Enum.map(Ash.Resource.Info.public_calculations(resource), & &1.name) ++
          Enum.map(Ash.Resource.Info.public_aggregates(resource), & &1.name)

      manifest_resource ->
        Ash.Info.Manifest.Resource.field_names(manifest_resource)
    end
  end

  @doc """
  The relationship `name` on `resource`, narrowed to `:name`, `:destination`
  and `:cardinality`, or `nil`.

  A miss on the manifest falls back to live introspection, because a manifest
  is not a complete list of relationships:
  `Ash.Info.Manifest.Generator.generate/1` defaults
  `:include_private_relationships?` to `false`
  (`deps/ash/lib/ash/info/manifest/generator.ex:50`), so a private `belongs_to`
  is absent from a manifest built with the defaults while
  `Ash.Resource.Info.relationship/2` still answers for it.
  """
  @spec relationship(module(), atom(), config()) :: relationship() | nil
  def relationship(resource, name, config \\ %{}) do
    case manifest_resource(config, resource) do
      nil ->
        narrow_relationship(Ash.Resource.Info.relationship(resource, name))

      manifest_resource ->
        case Ash.Info.Manifest.Resource.get_relationship(manifest_resource, name) do
          nil -> narrow_relationship(Ash.Resource.Info.relationship(resource, name))
          found -> narrow_relationship(found)
        end
    end
  end

  @doc """
  The public relationship `name` on `resource`, narrowed like `relationship/3`.

  The manifest carries only public relationships, so both sources agree.
  """
  @spec public_relationship(module(), atom(), config()) :: relationship() | nil
  def public_relationship(resource, name, config \\ %{}) do
    case manifest_resource(config, resource) do
      nil -> narrow_relationship(Ash.Resource.Info.public_relationship(resource, name))
      resource -> narrow_relationship(Ash.Info.Manifest.Resource.get_relationship(resource, name))
    end
  end

  @doc """
  How the read behind the `:many` relationship `name` paginates.

  `:offset`, `:keyset`, `:mixed` when the action offers both, and `:none` when
  it offers neither — which is also the answer for every to-one relationship
  and for a relationship nobody declared.

  Live, this walks to the destination's read action on every call. The
  decorator resolves it once per relationship at compile time. Precomputed for
  issue #24, the relationship query envelopes, which need the answer per
  relationship per request.
  """
  @spec relationship_pagination(module(), atom(), config()) ::
          :offset | :keyset | :mixed | :none
  def relationship_pagination(resource, name, config \\ %{}) do
    case decorated_relationship(config, resource, name) do
      nil -> resource |> live_read_action(name) |> pagination_kind()
      {relationship, namespace} -> Custom.relationship_pagination(relationship, namespace)
    end
  end

  @doc """
  The read action the `:many` relationship `name` loads through, or `nil`.

  The relationship's own `read_action` when it names one, the destination's
  primary read otherwise. `nil` for a to-one relationship, for a destination
  with no primary read, and for a relationship nobody declared.
  """
  @spec relationship_read_action(module(), atom(), config()) :: atom() | nil
  def relationship_read_action(resource, name, config \\ %{}) do
    case decorated_relationship(config, resource, name) do
      nil ->
        case live_read_action(resource, name) do
          nil -> nil
          action -> action.name
        end

      {relationship, namespace} ->
        Custom.relationship_read_action(relationship, namespace)
    end
  end

  # ---------------------------------------------------------------------------
  # Fields and actions
  #
  # Manifest-backed only where `AshIntrospection.Manifest.Decorator` has
  # written the data, because `%Ash.Info.Manifest.Field{}` cannot answer these
  # questions on its own: it carries a resolved `%Ash.Info.Manifest.Type{}`
  # where callers here read `{type, constraints}`, and it carries
  # `has_default?` where they read `default`. An undecorated resource — or no
  # manifest at all — reads live, and the two agree by construction. See the
  # decorator's moduledoc.
  # ---------------------------------------------------------------------------

  @doc "See `Ash.Resource.Info.attribute/2`."
  @spec attribute(module(), atom() | String.t(), config()) :: Ash.Resource.Attribute.t() | nil
  def attribute(resource, name, config \\ %{}) do
    case decorated(config, resource) do
      nil -> Ash.Resource.Info.attribute(resource, name)
      {manifest_resource, namespace} -> Custom.attribute(manifest_resource, name, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.attributes/1`."
  @spec attributes(module(), config()) :: [Ash.Resource.Attribute.t()]
  def attributes(resource, config \\ %{}) do
    case decorated(config, resource) do
      nil -> Ash.Resource.Info.attributes(resource)
      {manifest_resource, namespace} -> Custom.attributes(manifest_resource, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.public_attribute/2`."
  @spec public_attribute(module(), atom() | String.t(), config()) ::
          Ash.Resource.Attribute.t() | nil
  def public_attribute(resource, name, config \\ %{}) do
    case decorated(config, resource) do
      nil ->
        Ash.Resource.Info.public_attribute(resource, name)

      {manifest_resource, namespace} ->
        Custom.public_attribute(manifest_resource, name, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.public_attributes/1`."
  @spec public_attributes(module(), config()) :: [Ash.Resource.Attribute.t()]
  def public_attributes(resource, config \\ %{}) do
    case decorated(config, resource) do
      nil -> Ash.Resource.Info.public_attributes(resource)
      {manifest_resource, namespace} -> Custom.public_attributes(manifest_resource, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.calculation/2`."
  @spec calculation(module(), atom() | String.t(), config()) ::
          Ash.Resource.Calculation.t() | nil
  def calculation(resource, name, config \\ %{}) do
    case decorated(config, resource) do
      nil -> Ash.Resource.Info.calculation(resource, name)
      {manifest_resource, namespace} -> Custom.calculation(manifest_resource, name, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.public_calculation/2`."
  @spec public_calculation(module(), atom() | String.t(), config()) ::
          Ash.Resource.Calculation.t() | nil
  def public_calculation(resource, name, config \\ %{}) do
    case decorated(config, resource) do
      nil ->
        Ash.Resource.Info.public_calculation(resource, name)

      {manifest_resource, namespace} ->
        Custom.public_calculation(manifest_resource, name, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.public_calculations/1`."
  @spec public_calculations(module(), config()) :: [Ash.Resource.Calculation.t()]
  def public_calculations(resource, config \\ %{}) do
    case decorated(config, resource) do
      nil -> Ash.Resource.Info.public_calculations(resource)
      {manifest_resource, namespace} -> Custom.public_calculations(manifest_resource, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.aggregate/2`."
  @spec aggregate(module(), atom() | String.t(), config()) :: Ash.Resource.Aggregate.t() | nil
  def aggregate(resource, name, config \\ %{}) do
    case decorated(config, resource) do
      nil -> Ash.Resource.Info.aggregate(resource, name)
      {manifest_resource, namespace} -> Custom.aggregate(manifest_resource, name, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.public_aggregate/2`."
  @spec public_aggregate(module(), atom() | String.t(), config()) ::
          Ash.Resource.Aggregate.t() | nil
  def public_aggregate(resource, name, config \\ %{}) do
    case decorated(config, resource) do
      nil ->
        Ash.Resource.Info.public_aggregate(resource, name)

      {manifest_resource, namespace} ->
        Custom.public_aggregate(manifest_resource, name, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.public_aggregates/1`."
  @spec public_aggregates(module(), config()) :: [Ash.Resource.Aggregate.t()]
  def public_aggregates(resource, config \\ %{}) do
    case decorated(config, resource) do
      nil -> Ash.Resource.Info.public_aggregates(resource)
      {manifest_resource, namespace} -> Custom.public_aggregates(manifest_resource, namespace)
    end
  end

  @doc """
  See `Ash.Resource.Info.aggregate_type/2`.

  The decorator resolves this once per aggregate at compile time; live, it
  walks the relationship path to the aggregated field on every call. The
  `{:ok, type}` / `{:error, reason}` return shape is that function's and is
  passed through unchanged.
  """
  @spec aggregate_type(module(), Ash.Resource.Aggregate.t(), config()) :: term()
  def aggregate_type(resource, aggregate, config \\ %{}) do
    with {manifest_resource, namespace} <- decorated(config, resource),
         resolved when resolved != :undecorated <-
           Custom.aggregate_type(manifest_resource, aggregate, namespace) do
      resolved
    else
      _ -> Ash.Resource.Info.aggregate_type(resource, aggregate)
    end
  end

  @doc "See `Ash.Resource.Info.action/2`."
  @spec action(module(), atom(), config()) :: Ash.Resource.Actions.action() | nil
  def action(resource, name, config \\ %{}) do
    case decorated(config, resource) do
      nil -> Ash.Resource.Info.action(resource, name)
      {manifest_resource, namespace} -> Custom.action(manifest_resource, name, namespace)
    end
  end

  @doc "See `Ash.Resource.Info.actions/1`."
  @spec actions(module(), config()) :: [Ash.Resource.Actions.action()]
  def actions(resource, config \\ %{}) do
    case decorated(config, resource) do
      nil -> Ash.Resource.Info.actions(resource)
      {manifest_resource, namespace} -> Custom.actions(manifest_resource, namespace)
    end
  end

  @doc """
  Whether a bulk update or destroy on `resource` should authorize with
  `:error` or `:filter`.

  `:error` when the data layer can express errors in expressions, `:filter`
  otherwise — `Ash.DataLayer.data_layer_can?(resource, :expr_error)`. A data
  layer is fixed at compile time, so the decorator answers this once.
  """
  @spec authorize_bulk_strategy(module(), config()) :: :error | :filter
  def authorize_bulk_strategy(resource, config \\ %{}) do
    with {manifest_resource, namespace} <- decorated(config, resource),
         strategy when not is_nil(strategy) <-
           Custom.authorize_bulk_strategy(manifest_resource, namespace) do
      strategy
    else
      _ ->
        if Ash.DataLayer.data_layer_can?(resource, :expr_error), do: :error, else: :filter
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp known_resource?(source, module) do
    Map.has_key?(source.resources, module) or embedded_type?(source, module)
  end

  defp embedded_type?(source, module) do
    match?(%{kind: :embedded_resource}, Map.get(source.types, module))
  end

  # The `%Ash.Info.Manifest.Resource{}` for `resource`, or `nil` to read live.
  #
  # `nil` covers both "no manifest" and "this manifest does not carry the
  # module" — an embedded resource included. Manifest entries for embedded
  # resources hang off `type.resource`, so they are unwrapped here rather than
  # sending the caller to live introspection for a resource the manifest does
  # describe.
  defp manifest_resource(config, resource), do: manifest_resource_in(source(config), resource)

  defp manifest_resource_in(%Source{} = source, resource)
       when is_atom(resource) and not is_nil(resource) do
    case Map.get(source.resources, resource) do
      %Ash.Info.Manifest.Resource{} = manifest_resource ->
        manifest_resource

      _ ->
        case Map.get(source.types, resource) do
          %{kind: :embedded_resource, resource: %Ash.Info.Manifest.Resource{} = embedded} ->
            embedded

          _ ->
            nil
        end
    end
  end

  defp manifest_resource_in(_source, _resource), do: nil

  # The decorated `%Ash.Info.Manifest.Resource{}` for `resource` plus the
  # namespace it was decorated under, or `nil` to read live.
  #
  # `nil` covers three cases that a caller treats identically: no manifest, a
  # manifest that does not carry the module, and a manifest that carries it
  # undecorated. The last one is not hypothetical —
  # `AshIntrospection.Manifest.Decorator` skips a module it cannot load, so a
  # resource can be present and bare.
  defp decorated(config, resource) do
    with %Source{namespace: namespace} = source <- source(config),
         %Ash.Info.Manifest.Resource{} = manifest_resource <-
           manifest_resource_in(source, resource),
         true <- Custom.decorated?(manifest_resource, namespace) do
      {manifest_resource, namespace}
    else
      _ -> nil
    end
  end

  # The decorated `%Ash.Info.Manifest.Relationship{}` for `name` plus its
  # namespace, or `nil` to compute live. A private relationship is never in the
  # manifest, so this is `nil` for every one of them.
  defp decorated_relationship(config, resource, name) do
    with %Source{namespace: namespace} = source <- source(config),
         %Ash.Info.Manifest.Resource{} = manifest_resource <-
           manifest_resource_in(source, resource),
         %Ash.Info.Manifest.Relationship{} = relationship <-
           Ash.Info.Manifest.Resource.get_relationship(manifest_resource, name),
         true <- Custom.decorated?(relationship, namespace) do
      {relationship, namespace}
    else
      _ -> nil
    end
  end

  # The `%Ash.Resource.Actions.Read{}` a `:many` relationship loads through, or
  # `nil`. The relationship's own `read_action` wins over the destination's
  # primary read; a to-one relationship has neither, because it loads one
  # record and never paginates.
  #
  # `Code.ensure_loaded?/1` guards the destination for the reason #49 records:
  # the decorator runs at compile time, where a referenced module may not be
  # compiled yet, and an unloaded module would answer as though it declared
  # nothing.
  defp live_read_action(resource, name) do
    with %{cardinality: :many, destination: destination} = relationship <-
           Ash.Resource.Info.relationship(resource, name),
         true <- is_atom(destination) and Code.ensure_loaded?(destination) do
      case Map.get(relationship, :read_action) do
        nil -> Ash.Resource.Info.primary_action(destination, :read)
        read_action -> Ash.Resource.Info.action(destination, read_action)
      end
    else
      _ -> nil
    end
  end

  defp pagination_kind(%{pagination: %{offset?: true, keyset?: true}}), do: :mixed
  defp pagination_kind(%{pagination: %{offset?: true}}), do: :offset
  defp pagination_kind(%{pagination: %{keyset?: true}}), do: :keyset
  defp pagination_kind(_), do: :none

  defp narrow_relationship(nil), do: nil

  defp narrow_relationship(relationship) do
    %{
      name: relationship.name,
      destination: relationship.destination,
      cardinality: relationship.cardinality
    }
  end
end
