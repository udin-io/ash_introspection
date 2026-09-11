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
  the `:manifest` config key; `AshIntrospection.ResourceInfo.prepare/1` turns
  the first into the second. Preparing once and reusing the result is the
  supported shape — a bare manifest works and is O(resources) per read.
  """

  @typedoc "A manifest plus the module-keyed lookups read from it."
  @type t :: %__MODULE__{
          manifest: Ash.Info.Manifest.t(),
          resources: %{module() => Ash.Info.Manifest.Resource.t()},
          types: %{module() => Ash.Info.Manifest.Type.t()}
        }

  defstruct [:manifest, resources: %{}, types: %{}]

  @doc """
  Builds the lookup maps for `manifest`.

  Returns the source unchanged when it has already been prepared.
  """
  @spec new(Ash.Info.Manifest.t() | t()) :: t()
  def new(%__MODULE__{} = source), do: source

  def new(%Ash.Info.Manifest{} = manifest) do
    %__MODULE__{
      manifest: manifest,
      resources: Ash.Info.Manifest.resource_lookup(manifest),
      types: Ash.Info.Manifest.type_lookup(manifest)
    }
  end
end
