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

  describe "ErrorBuilder clauses that named a module or echoed a term" do
    test "invalid_field_format answers its own type, sends no term" do
      response = build({:invalid_field_format, %{"a" => 1, "b" => 2}, [:books]})

      assert response.type == "invalid_field_format"
      assert response.message == "Name one nested field per map in fields"
      assert response.path == ["books"]
      refute_internal(response)
    end

    test "unknown_field: a resource module is not named" do
      response = build({:unknown_field, :nope, AshIntrospection.Test.Policy.Memo, []})

      assert response.type == "unknown_field"
      assert response.message == "Unknown field %{field}"
      refute Map.has_key?(response.vars, :resource)
      refute_internal(response)
    end

    test "unknown_field: a container label is not named" do
      response = build({:unknown_field, :nope, "tuple", []})

      refute Map.has_key?(response.vars, :resource)
      refute_internal(response, ["tuple"])
    end

    test "tenant_required tuple does not name the resource" do
      response = build({:tenant_required, AshIntrospection.Test.Policy.Memo})

      assert response.type == "tenant_required"
      assert response.message == "Tenant parameter is required"
      assert response.vars == %{}
      refute_internal(response)
    end
  end

  describe "each Rpc.Error impl" do
    @memo AshIntrospection.Test.Policy.Memo

    for {label, module, opts} <- [
          {"NotFound", Ash.Error.Query.NotFound, [resource: @memo, primary_key: %{id: "x"}]},
          {"Changes.Required", Ash.Error.Changes.Required,
           [field: :slug, type: :attribute, resource: @memo]},
          {"Query.Required", Ash.Error.Query.Required,
           [field: :slug, type: :argument, resource: @memo]},
          {"ForbiddenField", Ash.Error.Forbidden.ForbiddenField, [resource: @memo, field: :body]},
          {"InvalidKeyset", Ash.Error.Page.InvalidKeyset, [value: "abc"]},
          {"InvalidPrimaryKey", Ash.Error.Invalid.InvalidPrimaryKey,
           [resource: @memo, value: "zz"]},
          {"ReadActionRequiresActor", Ash.Error.Query.ReadActionRequiresActor, []},
          {"InvalidChanges", Ash.Error.Changes.InvalidChanges, [fields: [:slug]]},
          {"InvalidQuery with a message", Ash.Error.Query.InvalidQuery,
           [field: :slug, message: "is invalid"]},
          {"InvalidQuery with no message", Ash.Error.Query.InvalidQuery, [field: :slug]},
          {"InvalidAttribute", Ash.Error.Changes.InvalidAttribute, [field: :slug]},
          {"Changes.InvalidArgument", Ash.Error.Changes.InvalidArgument, [field: :slug]},
          {"Query.InvalidArgument", Ash.Error.Query.InvalidArgument, [field: :slug]},
          {"UnknownError", Ash.Error.Unknown.UnknownError, [error: "host=10.0.0.5"]},
          {"TenantRequired", Ash.Error.Invalid.TenantRequired, [resource: @memo]},
          {"NoSuchInput", Ash.Error.Invalid.NoSuchInput,
           [resource: @memo, action: :create, input: :bogus_key, inputs: [:slug]]},
          {"NoSuchField", Ash.Error.Query.NoSuchField, [resource: @memo, field: "bogus_field"]},
          {"NoSuchFilterPredicate", Ash.Error.Query.NoSuchFilterPredicate,
           [resource: @memo, key: "bogus_op"]}
        ] do
      test "impl: #{label} names no module and no struct" do
        error = unquote(module).exception(unquote(Macro.escape(opts)))

        {[response], _log} = with_log(fn -> Errors.to_errors(error) end)

        refute response.type == "internal_error"
        refute_internal(response, ["10.0.0.5"])
      end
    end

    test "impl: ForbiddenField names the field in its message template" do
      [response] =
        Errors.to_errors(
          Ash.Error.Forbidden.ForbiddenField.exception(resource: @memo, field: :body)
        )

      assert response.message == "Forbidden: cannot access %{field}"
      assert response.vars == %{field: "body"}
    end

    test "impl: InvalidQuery with no message sends a fixed one" do
      [response] = Errors.to_errors(Ash.Error.Query.InvalidQuery.exception(field: :slug))

      assert response.message == "Invalid query"
    end

    test "impl: Forbidden with no inner error names no module" do
      [response] = Errors.to_errors(%Ash.Error.Forbidden{errors: []})

      assert response.type == "forbidden"
      refute_internal(response)
    end

    test "impl: InvalidPage names no module" do
      [response] = Errors.to_errors(Ash.Error.Query.InvalidPage.exception(page: [limit: -1]))

      refute_internal(response, ["Elixir.", "AshIntrospection", "Memo"])
    end

    test "no impl: an exception answers internal_error and names no module" do
      error = Ash.Error.Load.InvalidQuery.exception(resource: @memo, relationship: :x)

      {[response], log} = with_log(fn -> Errors.to_errors(error) end)

      assert response.type == "internal_error"
      assert log =~ response.error_id
      refute_internal(response)
    end
  end

  describe "values in an error's vars and path" do
    test "vars: a module atom is replaced" do
      assert vars_of(resource: AshIntrospection.Test.Policy.Memo).resource == "#Module<>"
    end

    test "vars: a module atom nested in a list, map and tuple is replaced" do
      vars =
        vars_of(
          list: [AshIntrospection.Test.Policy.Memo],
          map: %{r: AshIntrospection.Test.Policy.Memo},
          pair: {:resource, AshIntrospection.Test.Policy.Memo}
        )

      refute_internal(vars)
    end

    test "vars: a module atom as a map key is replaced" do
      refute_internal(vars_of(map: %{AshIntrospection.Test.Policy.Memo => 1}))
    end

    test "vars: a struct is replaced with a fixed placeholder" do
      {vars, log} =
        with_log(fn -> vars_of(owner: %Ash.ForbiddenField{original_value: "s3cret-original"}) end)

      assert vars.owner == "#Struct<>"
      refute_internal(vars, ["ForbiddenField", "s3cret"])
      assert log =~ "Ash.ForbiddenField"
    end

    test "vars: a port is replaced and the payload encodes" do
      port = Port.open({:spawn, "true"}, [])
      vars = vars_of(port: port)

      assert vars.port == "#Port<>"
      assert {:ok, _} = Jason.encode(vars)
    end

    test "vars: plain atoms, nil and booleans keep their value" do
      vars = vars_of(status: :archived, none: nil, yes: true, no: false)

      assert vars == %{status: "archived", none: nil, yes: true, no: false}
    end

    test "path: a module atom is replaced" do
      [response] =
        Errors.to_errors(
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :slug,
            path: [:memo, AshIntrospection.Test.Policy.Memo]
          )
        )

      refute_internal(response.path)
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

  defp vars_of(vars) do
    [response] =
      Errors.to_errors(Ash.Error.Changes.InvalidAttribute.exception(field: :slug, vars: vars))

    Map.drop(response.vars, [:field])
  end

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
