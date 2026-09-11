# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.TypeSystem.ResourceFields do
  @moduledoc """
  Provides unified resource field type lookup.

  This module centralizes the logic for looking up field types from Ash resources,
  supporting attributes, calculations, relationships, and aggregates.

  ## Variants

  - `get_field_type_info/2` - Looks up any field (public or private)
  - `get_public_field_type_info/2` - Looks up only public fields

  Both return `{type, constraints}` tuples, with `{nil, []}` for unknown fields.

  Every lookup goes through `AshIntrospection.ResourceInfo`, so an optional
  trailing `config` carrying a `:manifest` key answers from the manifest
  instead. Omitting it reads live `Ash.Resource.Info`, which is what every
  caller does today.
  """

  alias AshIntrospection.ResourceInfo

  @doc """
  Gets the type and constraints for any field on a resource.

  Checks attributes, calculations, relationships, and aggregates in order.
  Reaches private fields as well as public ones.

  ## Examples

      iex> get_field_type_info(MyApp.User, :name)
      {Ash.Type.String, []}

      iex> get_field_type_info(MyApp.User, :todos)
      {{:array, MyApp.Todo}, []}

      iex> get_field_type_info(MyApp.User, :unknown)
      {nil, []}
  """
  @spec get_field_type_info(module(), atom(), ResourceInfo.config()) ::
          {atom() | tuple() | nil, keyword()}
  def get_field_type_info(resource, field_name, config \\ %{}) do
    cond do
      attr = ResourceInfo.attribute(resource, field_name, config) ->
        {attr.type, attr.constraints || []}

      calc = ResourceInfo.calculation(resource, field_name, config) ->
        {calc.type, calc.constraints || []}

      rel = ResourceInfo.relationship(resource, field_name, config) ->
        type = if rel.cardinality == :many, do: {:array, rel.destination}, else: rel.destination
        {type, []}

      agg = ResourceInfo.aggregate(resource, field_name, config) ->
        {agg.type, agg.constraints || []}

      true ->
        {nil, []}
    end
  end

  @doc """
  Gets the type and constraints for public fields only.

  Checks public attributes, calculations, aggregates, and relationships in order.
  Used for output formatting where we only want publicly accessible fields.

  ## Examples

      iex> get_public_field_type_info(MyApp.User, :name)
      {Ash.Type.String, []}

      iex> get_public_field_type_info(MyApp.User, :private_field)
      {nil, []}
  """
  @spec get_public_field_type_info(module(), atom(), ResourceInfo.config()) ::
          {atom() | tuple() | nil, keyword()}
  def get_public_field_type_info(resource, field_name, config \\ %{}) do
    with nil <- ResourceInfo.public_attribute(resource, field_name, config),
         nil <- ResourceInfo.public_calculation(resource, field_name, config),
         nil <- ResourceInfo.public_aggregate(resource, field_name, config) do
      case ResourceInfo.public_relationship(resource, field_name, config) do
        nil ->
          {nil, []}

        rel ->
          type = if rel.cardinality == :many, do: {:array, rel.destination}, else: rel.destination
          {type, []}
      end
    else
      field -> {field.type, field.constraints || []}
    end
  end

  @doc """
  Gets the resolved type for an aggregate field.

  Aggregates can have computed types based on the underlying field type.
  This function returns the fully resolved aggregate type.

  ## Examples

      iex> get_aggregate_type_info(MyApp.User, :todo_count)
      {Ash.Type.Integer, []}
  """
  @spec get_aggregate_type_info(module(), atom(), ResourceInfo.config()) ::
          {atom() | nil, keyword()}
  def get_aggregate_type_info(resource, field_name, config \\ %{}) do
    case ResourceInfo.aggregate(resource, field_name, config) do
      nil ->
        {nil, []}

      agg ->
        resolved_type = ResourceInfo.aggregate_type(resource, agg, config)
        {resolved_type, []}
    end
  end
end
