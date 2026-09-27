# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.FieldFormatterSortStringTest do
  @moduledoc """
  `format_sort_string/2` lives in `FieldFormatter`, where the relationship
  query envelopes of #24 share it. `Pipeline.format_sort_string/2` stays public
  for `ash_kotlin_multiplatform`, which calls it, and gives the same answer.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.FieldFormatter
  alias AshIntrospection.Rpc.Pipeline

  @cases [
    {"--startDate,++insertedAt", "--start_date,++inserted_at"},
    {"-userName", "-user_name"},
    {"+userName,title", "+user_name,title"},
    {nil, nil}
  ]

  test "FieldFormatter converts each field and keeps its modifier" do
    for {input, expected} <- @cases do
      assert FieldFormatter.format_sort_string(input, :camel_case) == expected
    end
  end

  test "Pipeline.format_sort_string/2 gives the same answer" do
    for {input, expected} <- @cases do
      assert Pipeline.format_sort_string(input, :camel_case) == expected
    end
  end

  test "a name no field has comes back as a string" do
    name = "neverAField#{System.unique_integer([:positive])}"
    assert FieldFormatter.format_sort_string("-" <> name, :camel_case) =~ "-never_a_field"
  end
end
