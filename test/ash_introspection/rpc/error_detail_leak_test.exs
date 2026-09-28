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
  `Ash.Error.Unknown.UnknownError` carries the raw exception text. Both reach
  the client through the `AshIntrospection.Rpc.Error` protocol, so these tests
  assert on the payload a client would receive and scan it recursively for a
  sentinel rather than trusting a single key.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshIntrospection.Rpc.Error, as: ErrorProtocol
  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.Errors

  @actor_secret "sk-live-4f9c1a-ACTOR-SENTINEL"
  @policy_secret "only the owning tenant may read POLICY-SENTINEL"
  @exception_secret "postgres://appuser:hunter2@10.0.0.7/prod EXCEPTION-SENTINEL"

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

  describe "Ash.Error.Unknown.UnknownError" do
    test "returns a static message instead of the exception text" do
      error = Ash.Error.Unknown.UnknownError.exception(error: @exception_secret)

      assert Exception.message(error) =~ @exception_secret

      result = ErrorProtocol.to_error(error)

      assert result.message == "Something went wrong"
      assert result.short_message == "Unknown error"
      assert result.type == "unknown_error"
      refute leaks?(result)
    end

    test "does not leak the exception text through the full error pipeline" do
      [result] =
        Errors.to_errors(Ash.Error.Unknown.UnknownError.exception(error: @exception_secret))

      assert result.message == "Something went wrong"
      refute leaks?(result)
    end
  end

  # What an Elixir term or module name looks like once it is text: a module
  # (`Ash.Type.String`, `Elixir.Foo`), a struct or map literal, a tuple, an
  # opaque term other than the fixed placeholders.
  @internal_markers [
    "Elixir.",
    "AshIntrospection",
    "Memo",
    # A map literal, never a `%{field}` message placeholder.
    ~r/%\{(?![a-z_]+\})/,
    "=>",
    "{:",
    ~r/%[A-Z][\w.]*\{/,
    ~r/\b[A-Z]\w*\.[A-Z]\w*/,
    ~r/#(?!(Struct|Module|PID|Reference|Function|Port)<>)[A-Z][\w.]*</
  ]

  describe "ErrorBuilder fallbacks" do
    test "fallback: tagged pair sends no term, carries an error id" do
      response = build({:internal_state, %{api_key: "sk_live_123"}})

      assert response.type == "field_validation_error"
      refute Map.has_key?(response, :details)
      assert is_binary(response.error_id)
      refute_internal(response, ["sk_live_123", "api_key"])
    end

    test "fallback: string sends no term" do
      response = build("Postgrex connection refused host=10.0.0.5")

      assert response.type == "unknown_error"
      assert is_binary(response.error_id)
      refute_internal(response, ["10.0.0.5", "Postgrex"])
    end

    test "fallback: tuple sends no term" do
      response = build({:a, :b, %{secret: "s"}})

      assert response.type == "unknown_error"
      refute_internal(response, ["secret"])
    end

    test "fallback: bare atom sends no term" do
      response = build(:db_pool_exhausted)

      assert response.type == "unknown_error"
      refute_internal(response, ["db_pool_exhausted"])
    end

    test "fallback: inside a list sends no term" do
      [response] = build([{:internal_state, %{api_key: "sk_live_123"}}])

      assert is_binary(response.error_id)
      refute_internal(response, ["sk_live_123"])
    end

    test "fallback: the log carries the term and the id the client got" do
      {response, log} = with_log(fn -> build({:internal_state, %{api_key: "sk_live_123"}}) end)

      assert log =~ response.error_id
      assert log =~ ~s({:internal_state, %{api_key: "sk_live_123"}})
      assert response.message =~ response.error_id
    end
  end

  describe "ErrorBuilder clauses that hand the error to Errors" do
    test "RunStepError: the step's term sends nothing internal" do
      error = Reactor.Error.Invalid.RunStepError.exception(error: "db host=10.0.0.5", step: :s)

      [response] = List.wrap(build(error))

      refute_internal(response, ["10.0.0.5"])
    end

    test "a plain map sends nothing internal" do
      [response] = List.wrap(build(%{api_key: "sk_live_123"}))

      refute_internal(response, ["sk_live_123"])
    end
  end

  defp build(term), do: ErrorBuilder.build_error_response(term)

  defp refute_internal(payload, extra \\ []) do
    json = Jason.encode!(payload)

    for marker <- @internal_markers ++ extra do
      refute json =~ marker, "client payload matches #{inspect(marker)}: #{json}"
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
    Enum.any?([@actor_secret, @policy_secret, @exception_secret], &String.contains?(value, &1))
  end

  defp leaks?(%_{} = value), do: value |> Map.from_struct() |> leaks?()

  defp leaks?(value) when is_map(value) do
    Enum.any?(value, fn {key, val} -> leaks?(key) or leaks?(val) end)
  end

  defp leaks?(value) when is_list(value), do: Enum.any?(value, &leaks?/1)
  defp leaks?(value) when is_atom(value), do: leaks?(Atom.to_string(value))
  defp leaks?(_value), do: false
end
