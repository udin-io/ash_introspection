# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.ResourceInfo.Source do
  @moduledoc """
  A `%Ash.Info.Manifest{}` with its lookup maps already built.

  `Ash.Info.Manifest.resource_lookup/1` and `type_lookup/1` rebuild a map from
  a list on every call. `AshIntrospection.ResourceInfo` reads them dozens of
  times per request, so the maps are built once here and carried on the config
  map instead.

  Callers pass either a bare `%Ash.Info.Manifest{}` or a prepared source under
  the `:manifest` config key; `AshIntrospection.ResourceInfo.prepare/2` turns
  the first into the second. Preparing once and reusing the result is the
  supported shape — a bare manifest works and is O(resources) per read.

  The source also carries the `custom` namespace
  `AshIntrospection.Manifest.Decorator` wrote under, so a read knows where to
  find decorated data. It defaults to
  `AshIntrospection.Manifest.Custom.default_namespace/0`.
  """

  alias AshIntrospection.Manifest.Custom

  @typedoc "A manifest plus the module-keyed lookups read from it."
  @type t :: %__MODULE__{
          manifest: Ash.Info.Manifest.t(),
          namespace: atom(),
          resources: %{module() => Ash.Info.Manifest.Resource.t()},
          types: %{module() => Ash.Info.Manifest.Type.t()}
        }

  defstruct [:manifest, namespace: :ash_introspection, resources: %{}, types: %{}]

  @doc """
  Builds the lookup maps for `manifest`.

  Returns an already prepared source unchanged, except that an explicit
  `namespace` replaces the one it carries.
  """
  @spec new(Ash.Info.Manifest.t() | t(), atom() | nil) :: t()
  def new(manifest, namespace \\ nil)

  def new(%__MODULE__{} = source, nil), do: source
  def new(%__MODULE__{} = source, namespace), do: %__MODULE__{source | namespace: namespace}

  def new(%Ash.Info.Manifest{} = manifest, namespace) do
    %__MODULE__{
      manifest: manifest,
      namespace: namespace || Custom.default_namespace(),
      resources: Ash.Info.Manifest.resource_lookup(manifest),
      types: Ash.Info.Manifest.type_lookup(manifest)
    }
  end
end
