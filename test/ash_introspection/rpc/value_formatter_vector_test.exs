# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ValueFormatterVectorTest do
  @moduledoc """
  Pins what a client receives for an `Ash.Type.Vector` attribute.

  `%Ash.Vector{}` keeps its floats in a packed binary — `<<3, 0, 0, 0, 63,
  128, ...>>` — which `Jason` refuses to encode. `ValueFormatter` had no clause
  for the type, so the vector reached stage 4 as the post-`Map.from_struct`
  shape `%{data: <<...>>, dimensions: 3}` and either crashed the encoder or put
  a raw binary on the wire in place of the numbers.

  These tests drive a real vector attribute through the pipeline and assert the
  client gets a list of numbers that survives `Jason.encode!/1`.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Rpc.ValueFormatter
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.RpcDomain

  @embedding [0.5, -1.5, 2.25]

  setup do
    suffix = System.unique_integer([:positive])

    account =
      Account
      |> Ash.Changeset.for_create(:create, %{
        name: "Vector-#{suffix}",
        email: "vector-#{suffix}@example.com",
        embedding: @embedding
      })
      |> Ash.create!()

    %{account: account}
  end

  describe "a vector attribute on the output path" do
    test "reaches the client as a list of numbers", %{account: account} do
      response = read(account.email)

      assert response["embedding"] == @embedding
      assert Enum.all?(response["embedding"], &is_number/1)
    end

    test "survives JSON encoding", %{account: account} do
      json = account.email |> read() |> Jason.encode!()

      assert json =~ "0.5"
      assert json =~ "2.25"
    end

    test "a null vector stays null" do
      suffix = System.unique_integer([:positive])

      account =
        Account
        |> Ash.Changeset.for_create(:create, %{
          name: "NoVector-#{suffix}",
          email: "novector-#{suffix}@example.com"
        })
        |> Ash.create!()

      assert read(account.email)["embedding"] == nil
    end
  end

  describe "a vector reaching the formatter unnormalized" do
    test "an %Ash.Vector{} struct becomes a list of numbers" do
      assert {:ok, vector} = Ash.Vector.new(@embedding)

      assert ValueFormatter.format(vector, Ash.Type.Vector, [], :output) == @embedding
    end

    test "a list on the input path is left alone" do
      assert ValueFormatter.format(@embedding, Ash.Type.Vector, [], :input) == @embedding
    end
  end

  defp read(email) do
    request =
      Request.new(%{
        domain: RpcDomain,
        resource: Account,
        action: Ash.Resource.Info.action(Account, :get_account),
        rpc_action: %{},
        input: %{},
        context: %{},
        select: [:id, :name, :email, :embedding],
        load: [],
        extraction_template: [:id, :name, :email, :embedding],
        get_by: %{email: email}
      })

    assert {:ok, record} = Pipeline.execute_ash_action(request)
    assert {:ok, filtered} = Pipeline.process_result(record, request)

    response = Pipeline.format_output_with_request(%{success: true, data: filtered}, request)

    assert response["success"] == true
    response["data"]
  end
end
