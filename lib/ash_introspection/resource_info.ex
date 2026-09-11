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

  ## What the manifest answers in this stage

  Stage 1 installs the seam; it does not finish the migration. A function is
  backed by the manifest here only where both sources return the identical
  value:

  | Function | Manifest-backed |
  |---|---|
  | `runtime_resource?/2`, `declared_resource?/2`, `embedded?/2` | yes |
  | `primary_key/2`, `identity_keys/3` | yes |
  | `relationship/3`, `public_relationship/3` | yes |
  | `public_field_names/2` | yes |
  | every `attribute`, `calculation`, `aggregate`, `action` reader | no — live either way |

  The rest read live even when a manifest is present, and say so below. The
  reason is shape, not effort: `Ash.Info.Manifest.Field` carries a resolved
  `%Ash.Info.Manifest.Type{}` where `Ash.Resource.Attribute` carries an Ash
  type module plus a constraints keyword list. Translating between them is a
  real piece of work with its own failure modes, and it is what stage 2's
  decorator exists for. Half-translating it here would put a second, quieter
  answer next to the live one.

  **A manifest is not a complete list of relationships.**
  `Ash.Info.Manifest.Generator.generate/1` defaults
  `:include_private_relationships?` to `false`, so `relationship/3` falls back
  to live on a miss — a private `belongs_to` is absent from the manifest and
  present in `Ash.Resource.Info`. `public_relationship/3` does not fall back:
  every public relationship is carried, so a miss there is the answer.

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
  """
  @spec prepare(Ash.Info.Manifest.t() | Source.t() | nil) :: Source.t() | nil
  def prepare(nil), do: nil
  def prepare(manifest), do: Source.new(manifest)

  @doc """
  Normalizes the `:manifest` key on a config map with `prepare/1`.

  Call it once at an entry point rather than preparing on every read. A config
  with no `:manifest` key is returned untouched.
  """
  @spec normalize_config(map()) :: map()
  def normalize_config(config) when is_map(config) do
    case Map.get(config, :manifest) do
      nil -> config
      manifest -> Map.put(config, :manifest, prepare(manifest))
    end
  end

  @doc """
  Returns the prepared manifest source on `config`, or `nil` for live reads.
  """
  @spec source(config()) :: Source.t() | nil
  def source(config) when is_map(config), do: prepare(Map.get(config, :manifest))
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

  # ---------------------------------------------------------------------------
  # Live-only readers
  #
  # These take `config` so the call sites are already routed for stage 2, which
  # is where the manifest's resolved `%Ash.Info.Manifest.Type{}` gets
  # translated back into `{ash_type_module, constraints}`. Until then they
  # answer live whether or not a manifest is present, which is why they are
  # safe: the answer cannot disagree with itself.
  # ---------------------------------------------------------------------------

  @doc "See `Ash.Resource.Info.attribute/2`. Live in this stage."
  @spec attribute(module(), atom() | String.t(), config()) :: Ash.Resource.Attribute.t() | nil
  def attribute(resource, name, _config \\ %{}), do: Ash.Resource.Info.attribute(resource, name)

  @doc "See `Ash.Resource.Info.attributes/1`. Live in this stage."
  @spec attributes(module(), config()) :: [Ash.Resource.Attribute.t()]
  def attributes(resource, _config \\ %{}), do: Ash.Resource.Info.attributes(resource)

  @doc "See `Ash.Resource.Info.public_attribute/2`. Live in this stage."
  @spec public_attribute(module(), atom() | String.t(), config()) ::
          Ash.Resource.Attribute.t() | nil
  def public_attribute(resource, name, _config \\ %{}),
    do: Ash.Resource.Info.public_attribute(resource, name)

  @doc "See `Ash.Resource.Info.public_attributes/1`. Live in this stage."
  @spec public_attributes(module(), config()) :: [Ash.Resource.Attribute.t()]
  def public_attributes(resource, _config \\ %{}),
    do: Ash.Resource.Info.public_attributes(resource)

  @doc "See `Ash.Resource.Info.calculation/2`. Live in this stage."
  @spec calculation(module(), atom() | String.t(), config()) ::
          Ash.Resource.Calculation.t() | nil
  def calculation(resource, name, _config \\ %{}),
    do: Ash.Resource.Info.calculation(resource, name)

  @doc "See `Ash.Resource.Info.public_calculation/2`. Live in this stage."
  @spec public_calculation(module(), atom() | String.t(), config()) ::
          Ash.Resource.Calculation.t() | nil
  def public_calculation(resource, name, _config \\ %{}),
    do: Ash.Resource.Info.public_calculation(resource, name)

  @doc "See `Ash.Resource.Info.public_calculations/1`. Live in this stage."
  @spec public_calculations(module(), config()) :: [Ash.Resource.Calculation.t()]
  def public_calculations(resource, _config \\ %{}),
    do: Ash.Resource.Info.public_calculations(resource)

  @doc "See `Ash.Resource.Info.aggregate/2`. Live in this stage."
  @spec aggregate(module(), atom() | String.t(), config()) :: Ash.Resource.Aggregate.t() | nil
  def aggregate(resource, name, _config \\ %{}), do: Ash.Resource.Info.aggregate(resource, name)

  @doc "See `Ash.Resource.Info.public_aggregate/2`. Live in this stage."
  @spec public_aggregate(module(), atom() | String.t(), config()) ::
          Ash.Resource.Aggregate.t() | nil
  def public_aggregate(resource, name, _config \\ %{}),
    do: Ash.Resource.Info.public_aggregate(resource, name)

  @doc "See `Ash.Resource.Info.public_aggregates/1`. Live in this stage."
  @spec public_aggregates(module(), config()) :: [Ash.Resource.Aggregate.t()]
  def public_aggregates(resource, _config \\ %{}),
    do: Ash.Resource.Info.public_aggregates(resource)

  @doc "See `Ash.Resource.Info.aggregate_type/2`. Live in this stage."
  @spec aggregate_type(module(), Ash.Resource.Aggregate.t(), config()) :: term()
  def aggregate_type(resource, aggregate, _config \\ %{}),
    do: Ash.Resource.Info.aggregate_type(resource, aggregate)

  @doc "See `Ash.Resource.Info.action/2`. Live in this stage."
  @spec action(module(), atom(), config()) :: Ash.Resource.Actions.action() | nil
  def action(resource, name, _config \\ %{}), do: Ash.Resource.Info.action(resource, name)

  @doc "See `Ash.Resource.Info.actions/1`. Live in this stage."
  @spec actions(module(), config()) :: [Ash.Resource.Actions.action()]
  def actions(resource, _config \\ %{}), do: Ash.Resource.Info.actions(resource)

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
  defp manifest_resource(config, resource) when is_atom(resource) and not is_nil(resource) do
    with %Source{} = source <- source(config),
         nil <- Map.get(source.resources, resource) do
      case Map.get(source.types, resource) do
        %{kind: :embedded_resource, resource: %Ash.Info.Manifest.Resource{} = embedded} ->
          embedded

        _ ->
          nil
      end
    else
      nil -> nil
      %Ash.Info.Manifest.Resource{} = manifest_resource -> manifest_resource
    end
  end

  defp manifest_resource(_config, _resource), do: nil

  defp narrow_relationship(nil), do: nil

  defp narrow_relationship(relationship) do
    %{
      name: relationship.name,
      destination: relationship.destination,
      cardinality: relationship.cardinality
    }
  end
end
