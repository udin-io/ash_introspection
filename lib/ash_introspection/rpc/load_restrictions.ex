# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.LoadRestrictions do
  @moduledoc """
  Shapes the loadable surface of an RPC action: which relationships,
  calculations and aggregates a client may ask for.

  ## This is not authorization

  Load restrictions are an **API surface** tool, not a security boundary. The
  reason to reach for them is cost: keeping an expensive aggregate or a deep
  relationship off an endpoint that has no need for it, so a client cannot turn
  a list request into a report. They say nothing about who may see a value.

  Authorization is Ash's job and Ash still does it. Policies, field policies and
  tenancy apply to every load that gets through, exactly as they would if no
  restriction were declared. A field that must be hidden from an actor is hidden
  by a policy; adding it to `denied_loads` instead leaves it readable through
  every other action, and through any caller that is not this pipeline. Upstream
  `ash_typescript` states the same in `24266dc`.

  ## Where restrictions come from

  Upstream reads them from `Ash.Info.Manifest`, which this library has not
  adopted (issue #23). Here they arrive on the config map that already threads
  through field selection, under the `:load_restrictions` key:

      FieldSelector.process(resource, action, fields, %{
        load_restrictions: {:deny, [comments: [:score]]}
      })

  Omitting the key means `:none` — every load is permitted, which is what
  every existing caller gets.

  ## What a restriction says

  A restriction is `{:allow, spec}` or `{:deny, spec}`, where `spec` is a
  keyword-style nesting of internal (snake_case) field names:

  | Spec | Meaning |
  |---|---|
  | `{:deny, [:comments]}` | `comments` and everything under it is refused |
  | `{:deny, [comments: [:score]]}` | only `comments.score` is refused; `comments` itself is fine |
  | `{:allow, [:comments]}` | only `comments` may be loaded, and nothing deeper |
  | `{:allow, [comments: [:score]]}` | `comments` may be loaded as the step to `comments.score` |

  The two directions are deliberately not mirror images. `denied_loads`
  inherits downwards — denying a parent denies its children — because a deny
  list is a statement about a subtree. `allowed_loads` does not: allowing
  `comments` does not allow `comments.score`, because an allow list that
  inherited downwards would open a subtree its author never enumerated. Naming
  a nested path implicitly allows the parents needed to reach it, and only
  those.

  Attributes are never checked. They are selected, not loaded, so they never
  reach the load statement and no restriction can name one.

  ## How enforcement works

  `check!/2` is called by `AshIntrospection.Rpc.FieldProcessing.FieldSelector`
  at every point where it appends to the Ash load statement — six of them.
  A load therefore cannot reach the load statement without passing the check,
  so there is no second traversal that could disagree with field selection
  about what is being loaded. Nested paths are checked at every level as
  selection descends, not re-derived from the finished load statement
  afterwards.
  """

  @typedoc "A load path as a list of internal field names, e.g. `[:comments, :score]`."
  @type path :: [atom()]

  @typedoc "Normalized restrictions: the output of `normalize/1` and the input to `check!/2`."
  @type t :: :none | {:allow, [path()]} | {:deny, [path()]}

  @doc """
  Expands a restriction spec into a flat list of paths.

  Accepts `{:allow, spec}`, `{:deny, spec}` and anything else, which becomes
  `:none`. It is idempotent: passing its own output back returns that output,
  so a caller that pre-normalizes is not punished for it.

  Returns `t:t/0`.

      iex> AshIntrospection.Rpc.LoadRestrictions.normalize({:deny, [comments: [:score]]})
      {:deny, [[:comments, :score]]}
  """
  @spec normalize(term()) :: t()
  def normalize({:allow, allowed_loads}), do: {:allow, normalize_paths(List.wrap(allowed_loads))}
  def normalize({:deny, denied_loads}), do: {:deny, normalize_paths(List.wrap(denied_loads))}
  def normalize(_), do: :none

  @doc """
  Checks one load path against normalized restrictions.

  Returns `:ok`, or throws `{:load_not_allowed, [path_string]}` /
  `{:load_denied, [path_string]}` — the tuples
  `AshIntrospection.Rpc.ErrorBuilder` turns into a client error. It throws
  rather than returning an error tuple because its callers sit inside the
  recursive descent of field selection, which already reports every other
  refusal by throwing to `process/4`.

  The path string in the thrown tuple is the dotted internal path, e.g.
  `"comments.score"`, so the client is told which field it may not ask for.
  """
  @spec check!(path(), t()) :: :ok
  def check!(_path, :none), do: :ok

  def check!(path, {:allow, allowed_paths}) do
    if path_allowed?(path, allowed_paths) do
      :ok
    else
      throw({:load_not_allowed, [format_path(path)]})
    end
  end

  def check!(path, {:deny, denied_paths}) do
    if path_denied?(path, denied_paths) do
      throw({:load_denied, [format_path(path)]})
    else
      :ok
    end
  end

  defp normalize_paths(restrictions) when is_list(restrictions) do
    Enum.flat_map(restrictions, fn
      field when is_atom(field) ->
        [[field]]

      {field, nested} when is_atom(field) and is_list(nested) ->
        nested
        |> normalize_paths()
        |> Enum.map(fn nested_path -> [field | nested_path] end)

      # An already-normalized path, which keeps `normalize/1` idempotent.
      path when is_list(path) ->
        if Enum.all?(path, &is_atom/1), do: [path], else: []

      _ ->
        []
    end)
  end

  defp normalize_paths(_), do: []

  # Allowed if the path is named outright, or if it is a prefix of a named path
  # and therefore the step needed to reach it. Children of a named path are not
  # allowed — see the moduledoc on why the two directions differ.
  defp path_allowed?(path, allowed_paths) do
    Enum.any?(allowed_paths, fn allowed_path ->
      path == allowed_path or List.starts_with?(allowed_path, path)
    end)
  end

  # Denied if the path is named outright, or sits under a named path.
  defp path_denied?(path, denied_paths) do
    Enum.any?(denied_paths, fn denied_path ->
      path == denied_path or List.starts_with?(path, denied_path)
    end)
  end

  defp format_path(path), do: Enum.map_join(path, ".", &to_string/1)
end
