# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.ManifestTamper do
  @moduledoc """
  Writes a lie into a decorated manifest, so a test can prove a reader opens it.

  A parity test cannot prove that. `AshIntrospection.Manifest.Decorator`
  captures the live structs, so the manifest and `Ash.Resource.Info` agree by
  construction and every comparison passes whether or not the reader ever
  looked — the failure mode `CLAUDE.md` records against stage 4's dropped
  `:manifest` key. Making the two sources disagree is the only way to separate
  them: tamper with one decorated payload and assert the answer follows the
  tampered copy.

  Each function edits **every** place the decoration records the value, because
  a reader may take any of them. `AshIntrospection.Manifest.Decorator` writes an
  attribute into two lists and both key forms of the `by_name` map.
  """

  @doc """
  Replaces the decoration on `module` with `fun`'s result.

  The escape hatch for a lie the named functions below do not cover. `fun`
  receives the whole payload map.
  """
  @spec update_payload(Ash.Info.Manifest.t(), atom(), module(), (map() -> map())) ::
          Ash.Info.Manifest.t()
  def update_payload(manifest, namespace, module, fun) do
    resources =
      Enum.map(manifest.resources, fn
        %{module: ^module} = resource ->
          %{resource | custom: Map.update!(resource.custom, namespace, fun)}

        other ->
          other
      end)

    %{manifest | resources: resources}
  end

  @doc "Retypes one attribute, and clears its constraints with it."
  @spec retype(Ash.Info.Manifest.t(), atom(), module(), atom(), term()) :: Ash.Info.Manifest.t()
  def retype(manifest, namespace, module, field, type) do
    update_payload(manifest, namespace, module, fn payload ->
      payload
      |> Map.update!(:attributes, &retype_in_list(&1, field, type))
      |> Map.update!(:public_attributes, &retype_in_list(&1, field, type))
      |> update_by_name(:attributes, field, &retyped(&1, type))
    end)
  end

  @doc "Marks one attribute private."
  @spec hide(Ash.Info.Manifest.t(), atom(), module(), atom()) :: Ash.Info.Manifest.t()
  def hide(manifest, namespace, module, field) do
    update_payload(manifest, namespace, module, fn payload ->
      payload
      |> Map.update!(:public_attributes, &Enum.reject(&1, fn a -> a.name == field end))
      |> update_by_name(:attributes, field, &%{&1 | public?: false})
    end)
  end

  @doc """
  Moves `module` from the manifest's `types` into its `resources`.

  An embedded resource is carried under `types` with
  `kind: :embedded_resource`. Listed under `resources` instead,
  `AshIntrospection.ResourceInfo.embedded?/2` answers `false` without asking
  `Ash.Resource.Info`.
  """
  @spec declare_resource(Ash.Info.Manifest.t(), module()) :: Ash.Info.Manifest.t()
  def declare_resource(manifest, module) do
    %{
      manifest
      | resources: [%Ash.Info.Manifest.Resource{module: module} | manifest.resources],
        types: Enum.reject(manifest.types, &(&1.module == module))
    }
  end

  # Both key forms, mirroring what the decorator writes.
  defp update_by_name(payload, kind, name, fun) do
    Map.update!(payload, :by_name, fn by_name ->
      Map.update!(by_name, kind, fn entries ->
        entries
        |> Map.update!(name, fun)
        |> Map.update!(Atom.to_string(name), fun)
      end)
    end)
  end

  defp retype_in_list(attributes, field, type) do
    Enum.map(attributes, fn
      %{name: ^field} = attribute -> retyped(attribute, type)
      other -> other
    end)
  end

  defp retyped(attribute, type), do: %{attribute | type: type, constraints: []}
end
