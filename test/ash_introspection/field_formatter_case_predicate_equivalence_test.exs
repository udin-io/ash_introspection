# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.FieldFormatterCasePredicateEquivalenceTest do
  @moduledoc """
  Pins `format_field_name/2` against the regex predicates it used to run.

  Written for #61, which replaces `is_camel_case?/1`, `is_pascal_case?/1` and
  `is_snake_case?/1` with binary-matching clauses. Those three predicates decide
  whether a name is converted or returned untouched, so they set casing
  behaviour for every caller in the library — the RPC output path, codegen and
  error formatting alike. A binary walk that disagrees with the regex on one
  input silently changes the names clients see.

  `oracle/2` is the pre-#61 implementation, frozen: the same three regexes, the
  same `String.contains?/2`, the same `Helpers` calls in the same order. Every
  test here asserts the shipped function answers exactly what the oracle
  answers. Two PCRE details are load-bearing and the corpus covers both:
  `[a-z]` is ASCII-only with no `u` flag, so `ünter` is not lowercase, and `$`
  matches before a single trailing newline, so `"userN\\n"` is already camelCase
  (verified 2026-09-11 on OTP 27 / Elixir 1.18.4; `"abC\\r\\n"` and `"abC\\n\\n"`
  are not).

  Half the equivalence is invisible to a value assertion, so one test compares
  the *path* taken rather than the string returned — see the comment on
  `returned_untouched?/2`.

  A divergence here is a behaviour change, not a refactor. Update the oracle
  only with a decision recorded in `docs/decisions.md`.
  """

  use ExUnit.Case, async: true

  alias AshIntrospection.FieldFormatter
  alias AshIntrospection.Helpers

  @formatters [:camel_case, :pascal_case, :snake_case]

  # The awkward names already pinned elsewhere in the suite and in CLAUDE.md,
  # plus the unicode, whitespace and newline cases that separate a byte walk
  # from an ASCII regex.
  @curated [
    "_id",
    "_type",
    "_created_at",
    "field_1_name",
    "meta_1",
    "a__b",
    "id_",
    "http_url",
    "v2_token",
    "XMLParser",
    "_rev",
    "success",
    "data",
    "",
    "a",
    "A",
    "1",
    "_",
    "__",
    "aA",
    "ünter",
    "naïve_field",
    "user name",
    "user-name",
    "USER",
    "userName",
    "UserName",
    "user_name",
    "iOS",
    "aB1",
    "user\n",
    "userN\n",
    "a_b\n",
    "abC\r\n",
    "abC\r",
    "abC\n\n",
    "abC\v",
    "\nuser",
    "user\nname"
  ]

  describe "format_field_name/2 agrees with the pre-#61 regex predicates" do
    test "over every corpus name and every built-in formatter" do
      for name <- corpus(), formatter <- @formatters do
        assert FieldFormatter.format_field_name(name, formatter) == oracle(name, formatter),
               "#{inspect(formatter)} disagrees on #{inspect(name)}: " <>
                 "#{inspect(FieldFormatter.format_field_name(name, formatter))} " <>
                 "vs oracle #{inspect(oracle(name, formatter))}"
      end
    end

    test "under a second pass, which is where a double-format bug would show" do
      for name <- corpus(), formatter <- @formatters do
        once = FieldFormatter.format_field_name(name, formatter)
        twice = FieldFormatter.format_field_name(once, formatter)

        assert twice == oracle(oracle(name, formatter), formatter),
               "#{inspect(formatter)} disagrees on a second pass over #{inspect(name)}"
      end
    end

    test "taking the untouched-name path for exactly the names the regexes accept" do
      for name <- corpus(), name != "", formatter <- @formatters do
        assert returned_untouched?(name, formatter) == regex_predicate?(name, formatter),
               "#{inspect(formatter)} takes the wrong path for #{inspect(name)}: " <>
                 "regex says #{regex_predicate?(name, formatter)}"
      end
    end

    test "for atom input, which reaches the predicates through to_string/1" do
      for name <- [:user_name, :userName, :UserName, :_id, :field_1_name, :a__b],
          formatter <- @formatters do
        assert FieldFormatter.format_field_name(name, formatter) == oracle(name, formatter)
      end
    end
  end

  describe "named outputs" do
    # Measured 2026-09-11 at 74afafd. These are the answers the library gives
    # today, written out so a reader sees them without running the oracle.
    test "the awkward names keep the casing they have on main" do
      pins = [
        {"_id", "id", "Id", "_id"},
        {"_type", "type", "Type", "_type"},
        {"field_1_name", "field1Name", "Field1Name", "field_1_name"},
        {"meta_1", "meta1", "Meta1", "meta_1"},
        {"a__b", "aB", "AB", "a__b"},
        {"id_", "id", "Id", "id_"},
        {"http_url", "httpUrl", "HttpUrl", "http_url"},
        {"v2_token", "v2Token", "V2Token", "v2_token"},
        {"XMLParser", "xMLParser", "XMLParser", "xml_parser"},
        {"_rev", "rev", "Rev", "_rev"},
        {"success", "success", "Success", "success"},
        {"data", "data", "Data", "data"},
        {"userName", "userName", "UserName", "user_name"},
        {"user_name", "userName", "UserName", "user_name"}
      ]

      for {name, camel, pascal, snake} <- pins do
        assert FieldFormatter.format_field_name(name, :camel_case) == camel
        assert FieldFormatter.format_field_name(name, :pascal_case) == pascal
        assert FieldFormatter.format_field_name(name, :snake_case) == snake
      end
    end

    test "a name the formatter cannot derive survives one pass and not two" do
      # The CLAUDE.md lesson: _rev is the case that makes double formatting
      # visible, because it is pinned rather than derived.
      assert FieldFormatter.format_field_name("_rev", :camel_case) == "rev"
    end
  end

  # Every string of length 0..4 over a small alphabet, so the corpus covers
  # every arrangement of case, digit, underscore and trailing newline the
  # predicates can branch on.
  defp corpus do
    @curated ++ combinations(["a", "B", "1", "_"], 4) ++ combinations(["a", "B", "\n"], 3)
  end

  defp combinations(alphabet, max_length) do
    Enum.flat_map(0..max_length, fn length ->
      alphabet
      |> List.duplicate(length)
      |> cartesian()
      |> Enum.map(&Enum.join/1)
    end)
  end

  defp cartesian([]), do: [[]]

  defp cartesian([head | tail]) do
    rest = cartesian(tail)
    for item <- head, suffix <- rest, do: [item | suffix]
  end

  # A value assertion cannot see a predicate that answers `false` where the
  # regex answered `true`: every name a predicate accepts is a fixed point of
  # the conversion it skips (checked over 4681 names on 2026-09-11), so the
  # wrong path still produces the right string, only slower. What separates the
  # paths is the term: `format_field_name/2` hands back the binary it was given
  # when the predicate accepts, and builds a new one when it converts.
  # `:erts_debug.same/2` sees that, so it is how this file observes the
  # predicates at all. `""` is excluded because two empty binaries can be the
  # same term for reasons that have nothing to do with the branch taken.
  defp returned_untouched?(name, formatter) do
    :erts_debug.same(FieldFormatter.format_field_name(name, formatter), name)
  end

  defp regex_predicate?(name, :camel_case), do: regex_camel_case?(name)
  defp regex_predicate?(name, :pascal_case), do: regex_pascal_case?(name)
  defp regex_predicate?(name, :snake_case), do: regex_snake_case?(name)

  # --- The pre-#61 implementation, frozen. Do not "modernise" it. ---

  defp oracle(field_name, formatter) do
    string_field = to_string(field_name)

    case formatter do
      :camel_case ->
        if regex_camel_case?(string_field),
          do: string_field,
          else: Helpers.snake_to_camel_case(string_field)

      :pascal_case ->
        if regex_pascal_case?(string_field),
          do: string_field,
          else: Helpers.snake_to_pascal_case(string_field)

      :snake_case ->
        if regex_snake_case?(string_field),
          do: string_field,
          else: Helpers.camel_to_snake_case(string_field)
    end
  end

  defp regex_camel_case?(string) do
    String.match?(string, ~r/^[a-z][a-zA-Z0-9]*$/) && String.match?(string, ~r/[A-Z]/)
  end

  defp regex_pascal_case?(string) do
    String.match?(string, ~r/^[A-Z][a-zA-Z0-9]*$/)
  end

  defp regex_snake_case?(string) do
    String.match?(string, ~r/^[a-z][a-z0-9_]*$/) && String.contains?(string, "_")
  end
end
