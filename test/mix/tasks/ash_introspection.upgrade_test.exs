# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule Mix.Tasks.AshIntrospection.UpgradeTest do
  @moduledoc """
  0.3.0 renames the RPC error payload's `code` key to `type`, and this task is
  the migration that ships with it.

  The rewrite has no type information to lean on — `code` is an ordinary field
  name — so it is gated on the receiver being a bare variable named for an
  error. These tests pin both halves of that bargain: what it rewrites, and
  what it deliberately leaves for a human.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  describe "reading code off a variable named for an error" do
    test "rewrites dot access" do
      "error.code"
      |> upgrade()
      |> assert_has_patch("lib/my_app/rpc.ex", """
      - |    error.code
      + |    error.type
      """)
    end

    test "rewrites atom-key access" do
      "error[:code]"
      |> upgrade()
      |> assert_has_patch("lib/my_app/rpc.ex", """
      - |    error[:code]
      + |    error[:type]
      """)
    end

    test "rewrites string-key access" do
      ~s(error["code"])
      |> upgrade()
      |> assert_has_patch("lib/my_app/rpc.ex", """
      - |    error["code"]
      + |    error["type"]
      """)
    end

    test "rewrites the key argument to Map.get and friends" do
      for call <- [
            "Map.get(error, :code)",
            "Map.get(error, :code, nil)",
            ~s|Map.fetch(error, "code")|,
            ~s|Map.fetch!(error, "code")|,
            "Map.has_key?(error, :code)"
          ] do
        rewritten = String.replace(call, "code", "type")

        call
        |> upgrade()
        |> assert_has_patch("lib/my_app/rpc.ex", """
        - |    #{call}
        + |    #{rewritten}
        """)
      end
    end

    test "rewrites every name an error payload conventionally carries" do
      for name <- ["error", "err", "rpc_error", "validation_error"] do
        "#{name}.code"
        |> upgrade(receiver: name)
        |> assert_has_patch("lib/my_app/rpc.ex", """
        - |    #{name}.code
        + |    #{name}.type
        """)
      end
    end
  end

  describe "code read off anything else" do
    test "is left alone" do
      for {receiver, expression} <- [
            {"user", "user.code"},
            {"country", "country.code"},
            {"coupon", "coupon[:code]"},
            {"response", ~s(response["code"])},
            {"params", "Map.get(params, :code)"}
          ] do
        expression
        |> upgrade(receiver: receiver)
        |> assert_unchanged("lib/my_app/rpc.ex")
      end
    end

    test "leaves a pattern match alone, because the map could be anything" do
      "%{code: found} = error\n    found"
      |> upgrade()
      |> assert_unchanged("lib/my_app/rpc.ex")
    end

    test "leaves a receiver that is not a bare variable alone" do
      for expression <- ["fetch_error().code", "List.first(error).code", "Error.code"] do
        expression
        |> upgrade()
        |> assert_unchanged("lib/my_app/rpc.ex")
      end
    end
  end

  describe "the notice" do
    test "names the shapes a human still has to check" do
      "error.code"
      |> upgrade()
      |> assert_has_notice(&(&1 =~ "%{code:"))
    end
  end

  describe "0.4.0" do
    test "notices the three breaks, and rewrites nothing" do
      "error.code"
      |> upgrade(from: "0.3.0", to: "0.4.0")
      |> assert_unchanged("lib/my_app/rpc.ex")
      |> assert_has_notice(&(&1 =~ "identity_not_supported"))
      |> assert_has_notice(&(&1 =~ "invalid_identity"))
      |> assert_has_notice(&(&1 =~ "normalize_primitive/1"))
    end

    test "leaves an identity a read genuinely uses alone" do
      # A consumer builds one `%Request{}` for every action kind, so the
      # `identity:` key it sets is right for update and destroy and wrong only
      # for a read the client happens to name at runtime. Rewriting this is
      # what the codemod refuses to do.
      ~s|%AshIntrospection.Rpc.Request{identity: params["identity"]}|
      |> upgrade(from: "0.3.0", to: "0.4.0")
      |> assert_unchanged("lib/my_app/rpc.ex")
    end

    test "does not fire when 0.4.0 falls outside the range" do
      igniter = upgrade("error.code", from: "0.2.0", to: "0.3.0")

      refute Enum.any?(igniter.notices, &(&1 =~ "identity_not_supported"))
    end
  end

  describe "version selection" do
    test "does not rewrite code when 0.3.0 falls outside the range" do
      "error.code"
      |> upgrade(from: "0.3.0", to: "0.4.0")
      |> assert_unchanged("lib/my_app/rpc.ex")
    end

    test "runs when 0.3.0 falls inside the range" do
      "error.code"
      |> upgrade(from: "0.1.0", to: "0.9.0")
      |> assert_has_patch("lib/my_app/rpc.ex", """
      - |    error.code
      + |    error.type
      """)
    end
  end

  defp upgrade(body, opts \\ []) do
    from = Keyword.get(opts, :from, "0.2.0")
    to = Keyword.get(opts, :to, "0.3.0")
    receiver = Keyword.get(opts, :receiver, "error")

    [files: %{"lib/my_app/rpc.ex" => module_with(receiver, body)}]
    |> test_project()
    |> Igniter.compose_task("ash_introspection.upgrade", [from, to])
  end

  defp module_with(receiver, body) do
    """
    defmodule MyApp.Rpc do
      def read(#{receiver}) do
        #{body}
      end
    end
    """
  end
end
