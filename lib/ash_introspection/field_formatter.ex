# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.FieldFormatter do
  @moduledoc """
  Handles field name formatting for input parameters, output fields, and code generation.

  Supports built-in formatters (:camel_case, :pascal_case, :snake_case) and custom
  formatter functions specified as {module, function} or {module, function, extra_args}.
  """

  import AshIntrospection.Helpers

  @doc """
  Formats a field name using the configured formatter.

  ## Examples

      iex> AshIntrospection.FieldFormatter.format_field(:user_name, :camel_case)
      "userName"

      iex> AshIntrospection.FieldFormatter.format_field(:user_name, :snake_case)
      "user_name"

      iex> AshIntrospection.FieldFormatter.format_field(:user_name, :pascal_case)
      "UserName"
  """
  def format_field(field_name, formatter) when is_atom(field_name) or is_binary(field_name) do
    format_field_name(field_name, formatter)
  end

  @doc """
  Parses input field names from client format to internal format.

  This is used for converting incoming client field names to the internal
  Elixir atom keys that Ash expects.

  ## Examples

      iex> AshIntrospection.FieldFormatter.parse_input_field("userName", :camel_case)
      :user_name
  """
  def parse_input_field(field_name, formatter)
      when is_binary(field_name) or is_atom(field_name) do
    internal_name = parse_field_name(field_name, formatter)

    case internal_name do
      name when is_binary(name) ->
        try do
          String.to_existing_atom(name)
        rescue
          ArgumentError ->
            name
        end

      name when is_atom(name) ->
        name

      name ->
        name
    end
  end

  @doc """
  Formats a map of fields, converting all keys using the specified formatter.

  ## Examples

      iex> AshIntrospection.FieldFormatter.format_fields(%{user_name: "John", user_email: "john@example.com"}, :camel_case)
      %{"userName" => "John", "userEmail" => "john@example.com"}
  """
  def format_fields(fields, formatter) when is_map(fields) do
    Enum.into(fields, %{}, fn {key, value} ->
      formatted_key = format_field_name(key, formatter)
      {formatted_key, value}
    end)
  end

  @doc """
  Parses a map of input fields, converting all keys from client format to internal format.

  Recursively processes nested maps and arrays to ensure all field names are properly formatted.
  This is essential for union types and embedded resources that contain nested field structures.

  ## Examples

      iex> AshIntrospection.FieldFormatter.parse_input_fields(%{"userName" => "John", "userEmail" => "john@example.com"}, :camel_case)
      %{user_name: "John", user_email: "john@example.com"}

      iex> AshIntrospection.FieldFormatter.parse_input_fields(%{"attachments" => [%{"mimeType" => "pdf", "attachmentType" => "file"}]}, :camel_case)
      %{attachments: [%{mime_type: "pdf", attachment_type: "file"}]}
  """
  def parse_input_fields(fields, formatter) when is_map(fields) do
    Enum.into(fields, %{}, fn {key, value} ->
      internal_key = parse_input_field(key, formatter)
      formatted_value = parse_input_value(value, formatter)
      {internal_key, formatted_value}
    end)
  end

  @doc """
  Recursively parses input values, handling nested structures.

  This function ensures that all nested maps and arrays containing maps
  have their field names properly formatted according to the formatter.

  Only handles JSON-decoded data (maps, lists, primitives) - no structs.
  """
  def parse_input_value(value, formatter) do
    case value do
      map when is_map(map) ->
        parse_input_fields(map, formatter)

      list when is_list(list) ->
        Enum.map(list, fn item -> parse_input_value(item, formatter) end)

      primitive ->
        primitive
    end
  end

  @doc """
  Formats a field name using the configured formatter.

  ## Examples

      iex> AshIntrospection.FieldFormatter.format_field_name(:user_name, :camel_case)
      "userName"

      iex> AshIntrospection.FieldFormatter.format_field_name(:user_name, :snake_case)
      "user_name"

      iex> AshIntrospection.FieldFormatter.format_field_name("user_name", :pascal_case)
      "UserName"
  """
  def format_field_name(field_name, formatter) do
    string_field = to_string(field_name)

    case formatter do
      :camel_case ->
        if is_camel_case?(string_field) do
          string_field
        else
          snake_to_camel_case(string_field)
        end

      :pascal_case ->
        if is_pascal_case?(string_field) do
          string_field
        else
          snake_to_pascal_case(string_field)
        end

      :snake_case ->
        if is_snake_case?(string_field) do
          string_field
        else
          camel_to_snake_case(string_field)
        end

      {module, function} ->
        apply(module, function, [field_name])

      {module, function, extra_args} ->
        apply(module, function, [field_name | extra_args])

      _ ->
        raise ArgumentError, "Unsupported formatter: #{inspect(formatter)}"
    end
  end

  # The three predicates below walk bytes rather than run a regex. They answer
  # exactly what `~r/^[a-z][a-zA-Z0-9]*$/` and its two siblings answered before
  # #61 — `field_formatter_case_predicate_equivalence_test.exs` keeps the old
  # implementation as an oracle and compares the two over 420 names. Two details
  # of those regexes are reproduced on purpose: the character classes are
  # ASCII-only, because the regexes carried no `u` flag, and a single trailing
  # newline is accepted, because PCRE's `$` matches before one. Measured
  # 2026-09-11 on OTP 27 / Elixir 1.18.4: one `String.match?/2` call costs
  # ~300-370 ns and a whole walk ~10 ns.

  # camelCase: starts with lowercase, ASCII alphanumeric after it, and at least
  # one uppercase somewhere.
  defp is_camel_case?(<<char, rest::binary>>) when char >= ?a and char <= ?z,
    do: alphanumeric_tail?(rest, false)

  defp is_camel_case?(_string), do: false

  # PascalCase: starts with uppercase, ASCII alphanumeric after it. That leading
  # character already satisfies "has an uppercase", which is why PascalCase
  # shares camelCase's tail walk with the flag set.
  defp is_pascal_case?(<<char, rest::binary>>) when char >= ?A and char <= ?Z,
    do: alphanumeric_tail?(rest, true)

  defp is_pascal_case?(_string), do: false

  # snake_case: starts with lowercase, then lowercase, digits and underscores,
  # with at least one underscore.
  defp is_snake_case?(<<char, rest::binary>>) when char >= ?a and char <= ?z,
    do: snake_tail?(rest, false)

  defp is_snake_case?(_string), do: false

  defp alphanumeric_tail?(<<char, rest::binary>>, _uppercase?) when char >= ?A and char <= ?Z,
    do: alphanumeric_tail?(rest, true)

  defp alphanumeric_tail?(<<char, rest::binary>>, uppercase?)
       when (char >= ?a and char <= ?z) or (char >= ?0 and char <= ?9),
       do: alphanumeric_tail?(rest, uppercase?)

  defp alphanumeric_tail?("", uppercase?), do: uppercase?
  defp alphanumeric_tail?("\n", uppercase?), do: uppercase?
  defp alphanumeric_tail?(_rest, _uppercase?), do: false

  defp snake_tail?(<<?_, rest::binary>>, _underscore?), do: snake_tail?(rest, true)

  defp snake_tail?(<<char, rest::binary>>, underscore?)
       when (char >= ?a and char <= ?z) or (char >= ?0 and char <= ?9),
       do: snake_tail?(rest, underscore?)

  defp snake_tail?("", underscore?), do: underscore?
  defp snake_tail?("\n", underscore?), do: underscore?
  defp snake_tail?(_rest, _underscore?), do: false

  @doc """
  Recursively formats every key in a nested structure for client consumption.

  Walks maps and lists, converting each key with `formatter`. Structs and
  primitives are returned untouched, and a key that is neither an atom nor a
  binary is left as it is.

  Used for any payload handed to the client without passing through a
  type-driven formatter — the RPC response envelope and error payloads both
  rely on it, so their field names agree.

  ## Examples

      iex> AshIntrospection.FieldFormatter.format_output_field_names(%{short_message: "x"}, :camel_case)
      %{"shortMessage" => "x"}

      iex> AshIntrospection.FieldFormatter.format_output_field_names([%{user_name: "a"}], :camel_case)
      [%{"userName" => "a"}]
  """
  def format_output_field_names(data, formatter) do
    case data do
      map when is_map(map) and not is_struct(map) ->
        Enum.into(map, %{}, fn {key, value} ->
          formatted_key =
            case key do
              key when is_atom(key) or is_binary(key) -> format_field_name(key, formatter)
              other -> other
            end

          {formatted_key, format_output_field_names(value, formatter)}
        end)

      list when is_list(list) ->
        Enum.map(list, &format_output_field_names(&1, formatter))

      other ->
        other
    end
  end

  @doc """
  Resolves a field name to the atom that already names that field.

  Atoms pass through unchanged. A string is parsed into internal form by the
  formatter and resolved against the existing atom table; when no such atom
  exists the parsed string is returned unchanged.

  Every field a resource or type declares gets its atom at compile time, so a
  valid name always resolves. An unresolved name is one no field has, and
  callers compare the result against the declared field atoms — a string never
  matches one, so it fails as an unknown field.

  This deliberately never calls `String.to_atom/1`. Field names come from
  clients and the atom table is never garbage collected, so minting one atom per
  name lets an unauthenticated caller exhaust it and take the node down.

  ## Examples

      iex> AshIntrospection.FieldFormatter.resolve_field_name("userName", :camel_case)
      :user_name

      iex> AshIntrospection.FieldFormatter.resolve_field_name(:user_name, :snake_case)
      :user_name
  """
  def resolve_field_name(field_name, _formatter) when is_atom(field_name) do
    field_name
  end

  def resolve_field_name(field_name, formatter) when is_binary(field_name) do
    parse_input_field(field_name, formatter)
  end

  # Private helper for parsing field names from client format to internal format
  defp parse_field_name(field_name, formatter) do
    case formatter do
      :camel_case ->
        field_name |> to_string() |> camel_to_snake_case()

      :pascal_case ->
        field_name |> to_string() |> pascal_to_snake_case()

      :snake_case ->
        field_name |> to_string()

      {module, function} ->
        apply(module, function, [field_name])

      {module, function, extra_args} ->
        apply(module, function, [field_name | extra_args])

      _ ->
        raise ArgumentError, "Unsupported formatter: #{inspect(formatter)}"
    end
  end
end
