# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.TupleSelectionDomain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(AshIntrospection.Test.MapTile)
  end
end

defmodule AshIntrospection.Test.MapTile do
  @moduledoc """
  Fixture for #35: a tuple whose fields are themselves selectable.

  `Test.Post.get_bounds` — the only tuple action in the suite before this —
  carries two floats, so no field on it can take a nested spec and the
  `{:nested, ...}` branch of `FieldSelector.select_tuple_fields/4` had no
  fixture at all. `:get_tile` gives that branch one: `:corner` is a typed map
  with its own `:x` and `:y`, so the same field can be asked for flat and
  nested and the two answers compared.

  `private? true` on the ETS table for the reason `Test.Account` has it — see
  #55 and the note in `CLAUDE.md`. Writes must stay in the test process.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.TupleSelectionDomain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)

    # #89: the read-side twin of `:get_tile_map`. Ash casts an attribute, so
    # this path was already typed; it guards that the generic-action fix
    # leaves reads alone.
    attribute :area, :map do
      public?(true)

      constraints(
        fields: [
          name: [type: :string],
          span: [type: :tuple, constraints: [fields: [x: [type: :float], y: [type: :float]]]]
        ]
      )
    end
  end

  actions do
    defaults([:read])

    action :get_tile, :tuple do
      constraints(
        fields: [
          label: [type: :string],
          corner: [type: :map, constraints: [fields: [x: [type: :float], y: [type: :float]]]]
        ]
      )

      run(fn _input, _context -> {:ok, {"north-west", %{x: 1.5, y: 2.5}}} end)
    end

    # #66: two levels down. `:span` is a tuple of two tuples, so a nested
    # entry has to carry its index at every depth; `:meta` is a map holding a
    # map, so the same request shape can be checked where no index is needed.
    action :get_tile_deep, :tuple do
      constraints(
        fields: [
          label: [type: :string],
          span: [
            type: :tuple,
            constraints: [
              fields: [
                from: [
                  type: :tuple,
                  constraints: [fields: [x: [type: :float], y: [type: :float]]]
                ],
                to: [type: :tuple, constraints: [fields: [x: [type: :float], y: [type: :float]]]]
              ]
            ]
          ],
          meta: [
            type: :map,
            constraints: [
              fields: [
                origin: [
                  type: :map,
                  constraints: [fields: [lat: [type: :float], lng: [type: :float]]]
                ],
                zoom: [type: :integer]
              ]
            ]
          ]
        ]
      )

      run(fn _input, _context ->
        {:ok,
         {"north-west", {{1.5, 2.5}, {3.5, 4.5}}, %{origin: %{lat: 30.0, lng: 31.2}, zoom: 12}}}
      end)
    end

    # #66 neighbours: the same tuple reached through an array, a map field
    # and a union member, so each container's handling of a tuple index is
    # covered where no fixture existed before.
    action :list_tiles, {:array, :tuple} do
      constraints(
        items: [
          fields: [
            label: [type: :string],
            corner: [type: :map, constraints: [fields: [x: [type: :float], y: [type: :float]]]]
          ]
        ]
      )

      run(fn _input, _context ->
        {:ok, [{"north-west", %{x: 1.5, y: 2.5}}, {"south-east", %{x: 3.5, y: 4.5}}]}
      end)
    end

    # `:visible` holds `false` so a lookup that reads presence as truthiness
    # shows up as `nil` (#45, #89).
    action :get_tile_map, :map do
      constraints(
        fields: [
          name: [type: :string],
          span: [type: :tuple, constraints: [fields: [x: [type: :float], y: [type: :float]]]],
          visible: [type: :boolean]
        ]
      )

      run(fn _input, _context ->
        {:ok, %{name: "north-west", span: {1.5, 2.5}, visible: false}}
      end)
    end

    # #89: the same map built with string keys. Ash hands a `run` result
    # back uncast, so the keys reach `ResultProcessor` exactly as written.
    # `:visible` holds `false` so a lookup that reads presence as truthiness
    # shows up as `nil`.
    action :get_tile_map_strings, :map do
      constraints(
        fields: [
          name: [type: :string],
          span: [type: :tuple, constraints: [fields: [x: [type: :float], y: [type: :float]]]],
          meta: [type: :map, constraints: [fields: [zoom: [type: :integer]]]],
          visible: [type: :boolean]
        ]
      )

      run(fn _input, _context ->
        {:ok,
         %{
           "name" => "north-west",
           "span" => {1.5, 2.5},
           "meta" => %{"zoom" => 12},
           "visible" => false
         }}
      end)
    end

    action :list_tile_maps, {:array, :map} do
      constraints(
        items: [
          fields: [
            name: [type: :string],
            span: [type: :tuple, constraints: [fields: [x: [type: :float], y: [type: :float]]]]
          ]
        ]
      )

      run(fn _input, _context ->
        {:ok, [%{name: "north-west", span: {1.5, 2.5}}, %{name: "south-east", span: {3.5, 4.5}}]}
      end)
    end

    # A tuple in a map in a list in a map.
    action :get_region, :map do
      constraints(
        fields: [
          region: [type: :string],
          tiles: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  name: [type: :string],
                  span: [
                    type: :tuple,
                    constraints: [fields: [x: [type: :float], y: [type: :float]]]
                  ]
                ]
              ]
            ]
          ]
        ]
      )

      run(fn _input, _context ->
        {:ok,
         %{
           region: "north",
           tiles: [
             %{name: "north-west", span: {1.5, 2.5}},
             %{name: "north-east", span: {3.5, 4.5}}
           ]
         }}
      end)
    end

    action :get_tile_struct, :struct do
      constraints(
        fields: [
          name: [type: :string],
          span: [type: :tuple, constraints: [fields: [x: [type: :float], y: [type: :float]]]]
        ]
      )

      run(fn _input, _context -> {:ok, %{name: "north-west", span: {1.5, 2.5}}} end)
    end

    action :get_tile_keyword, :keyword do
      constraints(
        fields: [
          name: [type: :string],
          span: [type: :tuple, constraints: [fields: [x: [type: :float], y: [type: :float]]]]
        ]
      )

      run(fn _input, _context -> {:ok, [name: "north-west", span: {1.5, 2.5}]} end)
    end

    # `meta` declares `zoom` only; the action puts `secret` beside it.
    action :get_tile_meta, :map do
      constraints(
        fields: [
          name: [type: :string],
          meta: [type: :map, constraints: [fields: [zoom: [type: :integer]]]]
        ]
      )

      run(fn _input, _context ->
        {:ok, %{name: "north-west", meta: %{zoom: 12, secret: "s"}}}
      end)
    end

    # A tuple field selected flat, holding a map with an undeclared key.
    # Only stage 3 drops that key: stage 4 formats every key it is handed.
    action :get_tile_pin, :map do
      constraints(
        fields: [
          pin: [
            type: :tuple,
            constraints: [
              fields: [
                label: [type: :string],
                meta: [type: :map, constraints: [fields: [zoom: [type: :integer]]]]
              ]
            ]
          ]
        ]
      )

      run(fn _input, _context ->
        {:ok, %{pin: {"north-west", %{zoom: 12, secret: "s"}}}}
      end)
    end

    # #85: no return type, so Ash hands back `:ok`.
    action :touch_tile do
      run(fn _input, _context -> :ok end)
    end

    action :pick_tile, :union do
      constraints(
        types: [
          point: [type: :tuple, constraints: [fields: [x: [type: :float], y: [type: :float]]]],
          name: [type: :string]
        ]
      )

      run(fn _input, _context -> {:ok, %Ash.Union{type: :point, value: {1.5, 2.5}}} end)
    end
  end
end
