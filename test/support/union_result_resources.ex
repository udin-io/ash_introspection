# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.UnionResultDomain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(AshIntrospection.Test.Shelf)
  end
end

defmodule AshIntrospection.Test.ShelfSummary do
  @moduledoc """
  Embedded resource used as the `:summary` member of `Test.Shelf`'s unions.

  It has two attributes so a test can select one of them and see whether the
  other leaked through.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:label, :string, public?: true)
    attribute(:pages, :integer, public?: true)
  end
end

defmodule AshIntrospection.Test.Shelf do
  @moduledoc """
  Fixture for #84: union results that came back `nil`.

  `:content` and both generic actions share one union with a member of each
  kind: an embedded resource (`:summary`), a typed map (`:counts`) and a
  scalar (`:note`).

  `:badge` is declared first on purpose. `ResultProcessor` used to type a
  top-level `%Ash.Union{}` from the owning resource's first union attribute,
  so `:badge` names `:summary` with a different type and has no `:counts`.
  A generic action typed from `:badge` returns the wrong shape.

  `:pick_content` returns one union value, chosen by its `:member` argument.
  `:all_content` returns one value of each member, in member order.

  The `:counts` sample carries `internal_rank`, which `:counts` does not
  declare. A result typed from the action's own constraints drops it.

  `private? true` on the ETS table for the reason `Test.Account` has it — see
  #55 and the note in `CLAUDE.md`. Writes must stay in the test process.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.UnionResultDomain,
    data_layer: Ash.DataLayer.Ets

  @member_types [
    summary: [type: AshIntrospection.Test.ShelfSummary],
    counts: [
      type: :map,
      constraints: [
        fields: [
          book_count: [type: :integer],
          top_title: [type: :string]
        ]
      ]
    ],
    note: [type: :string]
  ]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)

    attribute(:badge, :union,
      public?: true,
      constraints: [types: [summary: [type: :string], note: [type: :string]]]
    )

    attribute(:content, :union, public?: true, constraints: [types: @member_types])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:title, :badge, :content])
    end

    action :pick_content, :union do
      constraints(types: @member_types)

      argument(:member, :atom,
        allow_nil?: false,
        constraints: [one_of: [:summary, :counts, :note]]
      )

      run(fn input, _context ->
        {:ok, AshIntrospection.Test.Shelf.sample(input.arguments.member)}
      end)
    end

    action :all_content, {:array, :union} do
      constraints(items: [types: @member_types])

      run(fn _input, _context ->
        {:ok, Enum.map([:summary, :counts, :note], &AshIntrospection.Test.Shelf.sample/1)}
      end)
    end
  end

  @doc "The union value each generic action hands back for `member`."
  def sample(:summary) do
    %Ash.Union{
      type: :summary,
      value: struct!(AshIntrospection.Test.ShelfSummary, label: "U", pages: 12)
    }
  end

  def sample(:counts) do
    %Ash.Union{type: :counts, value: %{book_count: 3, top_title: "C", internal_rank: 7}}
  end

  def sample(:note), do: %Ash.Union{type: :note, value: "plain"}
end
