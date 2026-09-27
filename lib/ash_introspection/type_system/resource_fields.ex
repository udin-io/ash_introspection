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
        aggregate_type_info(resource, agg, config)

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
      %Ash.Resource.Aggregate{} = agg -> aggregate_type_info(resource, agg, config)
      field -> {field.type, field.constraints || []}
    end
  end

  @doc """
  Gets the type and constraints of an aggregate's value.

  A declared type wins. A `first` aggregate takes the type and constraints of
  the field it reads, found by walking `relationship_path`; a `list` aggregate
  takes an array of them. Every other kind returns the type Ash resolves, with
  no constraints.

  ## Examples

      iex> get_aggregate_type_info(MyApp.User, :todo_count)
      {Ash.Type.Integer, []}
  """
  @spec get_aggregate_type_info(module(), atom(), ResourceInfo.config()) ::
          {atom() | tuple() | nil, keyword()}
  def get_aggregate_type_info(resource, field_name, config \\ %{}) do
    case ResourceInfo.aggregate(resource, field_name, config) do
      nil -> {nil, []}
      agg -> aggregate_type_info(resource, agg, config)
    end
  end

  # `agg.type` is `nil` for every aggregate that does not declare one, and
  # `ResourceInfo.aggregate_type/3` returns a type with no constraints. A
  # `first` or `list` over a union or an embedded resource needs both, so it
  # reads them off the field the aggregate reads.
  defp aggregate_type_info(_resource, %{type: type} = agg, _config) when not is_nil(type),
    do: {type, agg.constraints || []}

  defp aggregate_type_info(resource, %{kind: kind} = agg, config) when kind in [:first, :list] do
    case aggregated_field_type_info(resource, agg, config) do
      {nil, _} -> resolved_aggregate_type_info(resource, agg, config)
      {type, constraints} when kind == :first -> {type, constraints}
      {type, constraints} -> {{:array, type}, [items: constraints]}
    end
  end

  defp aggregate_type_info(resource, agg, config),
    do: resolved_aggregate_type_info(resource, agg, config)

  defp aggregated_field_type_info(resource, agg, config) do
    destination =
      Enum.reduce_while(agg.relationship_path, resource, fn name, current ->
        case ResourceInfo.relationship(current, name, config) do
          nil -> {:halt, nil}
          rel -> {:cont, rel.destination}
        end
      end)

    case {destination, agg.field} do
      {nil, _} -> {nil, []}
      {_, nil} -> {nil, []}
      {destination, field} -> get_field_type_info(destination, field, config)
    end
  end

  defp resolved_aggregate_type_info(resource, agg, config) do
    case ResourceInfo.aggregate_type(resource, agg, config) do
      {:ok, type} -> {type, []}
      _ -> {nil, []}
    end
  end
end
