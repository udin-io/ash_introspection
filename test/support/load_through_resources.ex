# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.LoadThrough.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(AshIntrospection.Test.LoadThrough.Owner)
    resource(AshIntrospection.Test.LoadThrough.Item)
  end
end

defmodule AshIntrospection.Test.LoadThrough.Shout do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, opts, _context), do: [opts[:field]]

  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, fn record ->
      case Map.get(record, opts[:field]) do
        nil -> nil
        value -> String.upcase(value)
      end
    end)
  end
end

defmodule AshIntrospection.Test.LoadThrough.Tag do
  @moduledoc """
  Embedded resource every composite field of `LoadThrough.Owner` holds.

  `:display_name` is multi-word, so a response that skips camelization shows
  `display_name` where `displayName` belongs. `:shout` is a calculation, so a
  selection can ask Ash to load through to it.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:label, :string, public?: true)
    attribute(:weight, :integer, public?: true)
    attribute(:display_name, :string, public?: true)
  end

  calculations do
    calculate(:shout, :string, {AshIntrospection.Test.LoadThrough.Shout, field: :label},
      public?: true
    )
  end
end

defmodule AshIntrospection.Test.LoadThrough.Item do
  @moduledoc """
  The related record behind `LoadThrough.Owner`'s aggregates.

  `private? true` on the ETS table for the reason `Test.Account` has it — see
  #55 and the note in `CLAUDE.md`. Writes must stay in the test process.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.LoadThrough.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:tag, AshIntrospection.Test.LoadThrough.Tag, public?: true)

    attribute(:extra, :union,
      public?: true,
      constraints: [
        types: [
          tag: [type: AshIntrospection.Test.LoadThrough.Tag],
          note: [type: :string]
        ]
      ]
    )
  end

  relationships do
    belongs_to(:owner, AshIntrospection.Test.LoadThrough.Owner, public?: true)
  end

  calculations do
    calculate(:loud_name, :string, {AshIntrospection.Test.LoadThrough.Shout, field: :name},
      public?: true
    )
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name, :tag, :extra, :owner_id])
    end
  end
end

defmodule AshIntrospection.Test.LoadThrough.Computed do
  @moduledoc false
  use Ash.Resource.Calculation

  alias AshIntrospection.Test.LoadThrough.{Item, Tag}

  @impl true
  def calculate(records, opts, _context), do: Enum.map(records, fn _ -> value(opts[:kind]) end)

  defp value(:top_tag), do: tag("Top", 1)
  defp value(:all_tags), do: [tag("One", 1), tag("Two", 2)]
  defp value(:best_item), do: struct!(Item, name: "best")
  defp value(:pick), do: %Ash.Union{type: :tag, value: tag("Picked", 3)}
  defp value(:stats), do: %{label: "stats", count: 2}

  defp tag(label, weight),
    do: struct!(Tag, label: label, weight: weight, display_name: label <> " name")
end

defmodule AshIntrospection.Test.LoadThrough.Owner do
  @moduledoc """
  Fixture for #25: a nested selection on a calculation returning a composite
  value, and on a `first` or `list` aggregate over an embedded resource or a
  union.

  Each calculation returns a fixed value, so a test can name every field it
  expects back. The aggregates read `LoadThrough.Item`.

  `private? true` on the ETS table for the reason `Test.Account` has it — see
  #55 and the note in `CLAUDE.md`. Writes must stay in the test process.
  """
  use Ash.Resource,
    domain: AshIntrospection.Test.LoadThrough.Domain,
    data_layer: Ash.DataLayer.Ets

  alias AshIntrospection.Test.LoadThrough.{Computed, Item, Tag}

  @member_types [tag: [type: Tag], note: [type: :string]]

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  relationships do
    has_many(:items, Item, public?: true)
  end

  calculations do
    calculate(:top_tag, Tag, {Computed, kind: :top_tag}, public?: true)
    calculate(:all_tags, {:array, Tag}, {Computed, kind: :all_tags}, public?: true)

    calculate(:best_item, :struct, {Computed, kind: :best_item},
      constraints: [instance_of: Item],
      public?: true
    )

    calculate(:pick, :union, {Computed, kind: :pick},
      constraints: [types: @member_types],
      public?: true
    )

    calculate(:stats, :map, {Computed, kind: :stats},
      constraints: [fields: [label: [type: :string], count: [type: :integer]]],
      public?: true
    )
  end

  aggregates do
    first(:first_tag, :items, :tag, public?: true, sort: [name: :asc])
    first(:first_extra, :items, :extra, public?: true, sort: [name: :asc])
    list(:all_item_tags, :items, :tag, public?: true, sort: [name: :asc])
    first(:first_name, :items, :name, public?: true, sort: [name: :asc])
    count(:item_count, :items, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:name])
    end
  end
end

defmodule AshIntrospection.Test.LoadThrough do
  @moduledoc """
  Runs a field selection on `LoadThrough.Owner`'s read through
  `FieldSelector.process/4` and the three `Pipeline` stages, as a consumer
  calls them.

  Returns `{:ok, data}` with the client JSON's `"data"`, or `{:error, error}`:
  a selection error as `ErrorBuilder` renders it for the client, or the error
  Ash returned for the load.
  """

  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.LoadThrough.{Domain, Item, Owner}
  alias AshIntrospection.Test.ManifestFixture

  @doc "The client response to `fields`, with `extra` merged into the config."
  def rpc(fields, extra \\ %{}) do
    config = ManifestFixture.decorated_config(extra)

    case FieldSelector.process(Owner, :read, fields, config) do
      {:error, error} ->
        {:error, ErrorBuilder.build_error_response(error)}

      {:ok, {select, load, template}} ->
        request =
          Request.new(%{
            domain: Domain,
            resource: Owner,
            action: Ash.Resource.Info.action(Owner, :read),
            rpc_action: %{},
            input: %{},
            context: %{},
            select: select,
            load: load,
            extraction_template: template,
            show_metadata: []
          })

        with {:ok, result} <- Pipeline.execute_ash_action(request, config),
             {:ok, processed} <- Pipeline.process_result(result, request, config) do
          %{"data" => data} =
            Pipeline.format_output_with_request(
              %{success: true, data: processed},
              request,
              config
            )

          {:ok, data}
        end
    end
  end

  @doc """
  One owner with two items. The aggregates sort by item name, so `i1` is first.
  """
  def seed! do
    owner = Owner |> Ash.Changeset.for_create(:create, %{name: "a"}) |> Ash.create!()

    item!(owner, "i1", tag("red", "Red"), %Ash.Union{type: :tag, value: tag("blue", "Blue")})
    item!(owner, "i2", tag("green", "Green"), %Ash.Union{type: :note, value: "memo"})
    owner
  end

  @doc "An owner with no items."
  def seed_empty!, do: Owner |> Ash.Changeset.for_create(:create, %{name: "b"}) |> Ash.create!()

  defp item!(owner, name, tag, extra) do
    Item
    |> Ash.Changeset.for_create(:create, %{name: name, tag: tag, extra: extra, owner_id: owner.id})
    |> Ash.create!()
  end

  defp tag(label, display_name), do: %{label: label, weight: 1, display_name: display_name}
end
