# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.ErrorsJsonSafetyTest do
  @moduledoc """
  An error's `vars` and `path` come from whatever built the error, so they can
  hold any Erlang term - a PID from a process that failed, a monitor
  reference, a callback, an internal struct. The RPC payload is handed to a
  JSON encoder, which raises on anything it has no representation for: the
  request then dies at the encoder instead of returning the error.

  Unwrapping a struct into its fields is the other half of the problem. It
  encodes, but it discloses every field the struct carries, including the ones
  the struct hides from `Inspect` precisely because the client must not see
  them.

  These tests pin the last step of the error pipeline: whatever reaches the
  client is JSON-encodable, and terms with no safe representation are reduced
  to an opaque marker rather than unwrapped.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshIntrospection.Rpc.Errors

  # Encodability is asserted with Jason, not the stdlib `JSON` module. `mix.exs`
  # declares `elixir: "~> 1.15"` and `JSON` only exists from 1.18, so `JSON` here
  # would fail to compile on a supported version. Ash depends on Jason
  # non-optionally, so it is always available.

  @secret "sk_live_do_not_disclose"

  defmodule Envelope do
    @moduledoc false
    defstruct [:label, :token]
  end

  describe "terms with no JSON representation" do
    test "replaces a pid with an opaque term" do
      assert vars_of(pid: self())[:pid] == "#PID<>"
    end

    test "replaces a reference with an opaque term" do
      assert vars_of(ref: make_ref())[:ref] == "#Reference<>"
    end

    test "replaces an anonymous function with an opaque term" do
      assert vars_of(fun: fn -> :ok end)[:fun] == "#Function<>"
    end

    test "replaces a pid in the error path with an opaque term" do
      [response] = to_errors(error(path: [:profile, self()]))

      assert response.path == ["profile", "#PID<>"]
    end
  end

  describe "an unknown struct" do
    test "is reduced to its module name" do
      {vars, _log} =
        with_log(fn -> vars_of(envelope: %Envelope{label: "api key", token: @secret}) end)

      assert vars[:envelope] == "##{inspect(Envelope)}<>"
    end

    test "does not disclose the fields it carries" do
      {[response], _log} =
        with_log(fn -> to_errors(error(vars: [envelope: %Envelope{token: @secret}])) end)

      refute leaks_secret?(response)
    end

    test "is logged with the module that was dropped" do
      {_response, log} =
        with_log(fn -> to_errors(error(vars: [envelope: %Envelope{token: @secret}])) end)

      assert log =~ inspect(Envelope)
      assert log =~ "serializing an RPC error"
      refute log =~ @secret
    end
  end

  describe "the payload handed to the client" do
    test "encodes as JSON with every unencodable term present" do
      {[response], _log} =
        with_log(fn ->
          to_errors(
            error(
              vars: [
                pid: self(),
                ref: make_ref(),
                fun: fn -> :ok end,
                envelope: %Envelope{token: @secret},
                nested: %{deeper: [self()]},
                pair: {:timeout, 500}
              ],
              path: [:profile, self()]
            )
          )
        end)

      assert is_binary(Jason.encode!(response))
      refute leaks_secret?(response)
    end
  end

  describe "values that already have a representation" do
    test "keeps binaries, numbers and booleans" do
      vars = vars_of(name: "Ada", count: 3, ratio: 1.5, active: true)

      assert vars[:name] == "Ada"
      assert vars[:count] == 3
      assert vars[:ratio] == 1.5
      assert vars[:active] == true
    end

    test "stringifies atoms" do
      assert vars_of(status: :archived)[:status] == "archived"
    end

    test "turns a tuple into a list" do
      assert vars_of(pair: {:timeout, 500})[:pair] == ["timeout", 500]
    end

    test "turns a keyword list into a map" do
      assert vars_of(opts: [retries: 2])[:opts] == %{"retries" => 2}
    end

    test "walks a nested map" do
      assert vars_of(limits: %{max: 10})[:limits] == %{max: 10}
    end

    test "renders dates and times as iso8601" do
      vars = vars_of(at: ~U[2026-02-14 01:02:03Z], on: ~D[2026-02-14])

      assert vars[:at] == "2026-02-14T01:02:03Z"
      assert vars[:on] == "2026-02-14"
    end

    test "renders a decimal as a plain string" do
      assert vars_of(amount: Decimal.new("10.50"))[:amount] == "10.50"
    end

    test "renders an Ash.CiString as its value" do
      assert vars_of(email: Ash.CiString.new("Ada@Example.com"))[:email] == "Ada@Example.com"
    end

    test "encodes the whole payload as JSON" do
      [response] = to_errors(error(vars: [pair: {:timeout, 500}, at: ~U[2026-02-14 01:02:03Z]]))

      assert is_binary(Jason.encode!(response))
    end
  end

  defp vars_of(vars) do
    [response] = to_errors(error(vars: vars))

    response.vars
  end

  defp error(opts) do
    [field: :profile, message: "invalid"]
    |> Keyword.merge(opts)
    |> Ash.Error.Changes.InvalidAttribute.exception()
  end

  defp to_errors(error), do: Errors.to_errors(error, nil, nil, nil, %{}, %{})

  defp leaks_secret?(value) when is_binary(value), do: String.contains?(value, @secret)
  defp leaks_secret?(value) when is_atom(value), do: leaks_secret?(Atom.to_string(value))
  defp leaks_secret?(%_{} = value), do: value |> Map.from_struct() |> leaks_secret?()

  defp leaks_secret?(value) when is_map(value) do
    Enum.any?(value, fn {key, val} -> leaks_secret?(key) or leaks_secret?(val) end)
  end

  defp leaks_secret?(value) when is_list(value), do: Enum.any?(value, &leaks_secret?/1)
  defp leaks_secret?(value) when is_tuple(value), do: value |> Tuple.to_list() |> leaks_secret?()
  defp leaks_secret?(_value), do: false
end
