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
  end
end
