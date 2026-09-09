# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorDetailLeakTest do
  @moduledoc """
  Guards the client-facing error payload against disclosing server internals.

  `Ash.Error.Forbidden.Policy.message/1` renders the entire authorization
  report — every policy, every check outcome, and the actor inspected in full
  — whenever the struct's `policy_breakdown?` flag is set, and Ash sets that
  flag from its own app-wide `:ash, :policies` toggle at exception time.
  The report reaches the client through the `AshIntrospection.Rpc.Error`
  protocol, so these tests assert on the payload a client would receive and scan
  it recursively for a sentinel rather than trusting a single key.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Rpc.Error, as: ErrorProtocol
  alias AshIntrospection.Rpc.Errors

  @actor_secret "sk-live-4f9c1a-ACTOR-SENTINEL"
  @policy_secret "only the owning tenant may read POLICY-SENTINEL"

  setup do
    on_exit(fn ->
      Application.delete_env(:ash_introspection, :policies)
      Application.delete_env(:ash, :policies)
    end)
  end

  describe "Ash.Error.Forbidden.Policy" do
    test "message is static when no breakdown config is set" do
      result = ErrorProtocol.to_error(policy_error())

      assert result.message == "forbidden"
      assert result.short_message == "Forbidden"
      assert result.type == "forbidden"
    end

    test "never attaches a policy_breakdown key" do
      Application.put_env(:ash, :policies, show_policy_breakdowns?: true)
      Application.put_env(:ash_introspection, :policies, show_policy_breakdowns?: true)

      refute Map.has_key?(ErrorProtocol.to_error(policy_error()), :policy_breakdown)
    end

    test "does not leak the report when Ash's own app-wide toggle is enabled" do
      Application.put_env(:ash, :policies, show_policy_breakdowns?: true)

      error = policy_error()

      # Ash's message/1 is the leak this fix exists to close.
      assert Exception.message(error) =~ @actor_secret
      assert Exception.message(error) =~ @policy_secret

      result = ErrorProtocol.to_error(error)

      assert result.message == "forbidden"
      refute leaks?(result)
    end

    test "does not leak the report through the full error pipeline" do
      Application.put_env(:ash, :policies, show_policy_breakdowns?: true)

      [result] = Errors.to_errors(policy_error())

      assert result.message == "forbidden"
      refute leaks?(result)
    end

    test "includes the report when ash_introspection is explicitly opted in" do
      Application.put_env(:ash_introspection, :policies, show_policy_breakdowns?: true)

      result = ErrorProtocol.to_error(policy_error())

      assert result.message =~ "Policy Breakdown"
      assert result.message =~ @policy_secret
      assert result.short_message == "Forbidden"
    end

    test "opted-in breakdown does not depend on Ash's app-wide toggle" do
      Application.put_env(:ash_introspection, :policies, show_policy_breakdowns?: true)
      Application.put_env(:ash, :policies, show_policy_breakdowns?: false)

      assert ErrorProtocol.to_error(policy_error()).message =~ "Policy Breakdown"
    end

    test "opted-in payload still encodes to JSON" do
      Application.put_env(:ash_introspection, :policies, show_policy_breakdowns?: true)

      [result] = Errors.to_errors(policy_error())

      assert {:ok, _json} = Jason.encode(result)
    end
  end

  defp policy_error do
    Ash.Error.Forbidden.Policy.exception(
      resource: AshIntrospection.Test.Account,
      action: :read,
      actor: %{id: "user_1", api_token: @actor_secret},
      policies: [
        %Ash.Policy.Policy{
          description: @policy_secret,
          condition: [],
          policies: [],
          bypass?: false,
          access_type: :strict
        }
      ],
      facts: %{},
      must_pass_strict_check?: false
    )
  end

  defp leaks?(value) when is_binary(value) do
    Enum.any?([@actor_secret, @policy_secret], &String.contains?(value, &1))
  end

  defp leaks?(%_{} = value), do: value |> Map.from_struct() |> leaks?()

  defp leaks?(value) when is_map(value) do
    Enum.any?(value, fn {key, val} -> leaks?(key) or leaks?(val) end)
  end

  defp leaks?(value) when is_list(value), do: Enum.any?(value, &leaks?/1)
  defp leaks?(value) when is_atom(value), do: leaks?(Atom.to_string(value))
  defp leaks?(_value), do: false
end
