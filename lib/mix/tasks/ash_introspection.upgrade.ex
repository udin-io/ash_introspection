# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshIntrospection.Upgrade do
    # Ships the codemods for every breaking release, so `mix igniter.upgrade
    # ash_introspection` migrates consumer code instead of leaving it to a hand
    # search. `mix ash_introspection.upgrade <from> <to>` runs it directly.
    #
    # `upgrades` is keyed by the version that shipped the break. An entry runs
    # when its key falls in `> from and <= to`, so there is one entry per
    # releasing version and never a range.
    #
    # ## 0.3.0 — `error.code` becomes `error.type`
    #
    # The RPC error payload named its class under `code` on some paths and
    # `type` on others. 0.3.0 unified it on `type`.
    #
    # `code` is an ordinary field name and the rewrite has no type information
    # to lean on, so it is gated on the receiver being a bare variable named
    # for an error. It rewrites `receiver.code`, `receiver[:code]`,
    # `receiver["code"]`, and the key argument to `Map.get/2,3`, `Map.fetch/2`,
    # `Map.fetch!/2` and `Map.has_key?/2`.
    #
    # What it deliberately will not touch, and why:
    #
    #   * A pattern match — `%{code: code} = error`, or a function head
    #     matching `%{code: code}`. The map being matched is not named at the
    #     match site, so the pattern could belong to anything.
    #   * A receiver that is not a bare variable: `List.first(errors).code`,
    #     `fetch_error().code`, `result.error.code`. Naming the receiver is the
    #     whole safety gate.
    #   * A variable whose name does not read as an error: `e`, `payload`,
    #     `result`. A false rewrite of an unrelated `code` field costs more
    #     than a missed one.
    #   * Anything outside Elixir source. Generated TypeScript and Kotlin
    #     clients read `error.code` too; regenerate them instead.
    #
    # The task emits a notice listing those cases, so the search left to a
    # human is a short one.
    @moduledoc false

    use Igniter.Mix.Task

    alias Sourceror.Zipper

    # Variables an RPC error payload is conventionally bound to. A receiver
    # named anything else is left alone.
    @error_names ~w(error err rpc_error)
    @error_name_suffix "_error"

    @map_accessors [:get, :fetch, :fetch!, :has_key?]

    @manual_check_notice """
    ash_introspection 0.3.0 renamed the RPC error payload's `code` key to `type`.

    The codemod rewrote `code` reads off variables named for an error. It could
    not decide these, so check them by hand:

      * pattern matches, such as `%{code: code} = error` or a function head
        matching `%{code: code}` - the map is not named at the match site
      * reads off an expression rather than a variable, such as
        `List.first(errors).code` or `result.error.code`
      * reads off a variable whose name does not read as an error, such as
        `payload.code`
      * generated TypeScript and Kotlin clients - regenerate them

    `grep -rn "code" --include="*.ex" --include="*.exs" .` narrows it down.
    """

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_introspection,
        example: "mix ash_introspection.upgrade 0.2.0 0.3.0",
        positional: [:from, :to]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      positional = igniter.args.positional
      options = igniter.args.options

      upgrades = %{
        "0.3.0" => [&rewrite_error_code_to_type/2]
      }

      Igniter.Upgrades.run(igniter, positional.from, positional.to, upgrades,
        custom_opts: options
      )
    end

    @doc false
    def rewrite_error_code_to_type(igniter, _opts) do
      igniter
      |> include_elixir_files()
      |> Igniter.update_all_elixir_files(fn zipper ->
        {:ok, Zipper.traverse(zipper, &rewrite_code_read/1)}
      end)
      |> Igniter.add_notice(@manual_check_notice)
    end

    # `Igniter.update_all_elixir_files/2` leans on `Igniter.include_glob/2` to
    # pull each file into the rewrite, and under `Igniter.Test` — where the
    # project lives in memory rather than on disk — that only resolves an
    # absolute glob (igniter 0.8.4, `deps/igniter/lib/igniter.ex:266`).
    # Including the files up front with expanded globs makes the codemod behave
    # the same in a test project as in a real one. It deliberately does not call
    # `Igniter.include_all_elixir_files/1`, which sets the flag that makes
    # `update_all_elixir_files/2` a no-op.
    defp include_elixir_files(igniter) do
      igniter
      |> Igniter.Project.IgniterConfig.get(:source_folders)
      |> Enum.map(&Path.join(&1, "**/*.{ex,exs}"))
      |> Enum.concat(["{test,config}/**/*.{ex,exs}"])
      |> Enum.reduce(igniter, fn glob, igniter ->
        Igniter.include_glob(igniter, Path.expand(glob))
      end)
    end

    # `error.code` and `error.code()`.
    defp rewrite_code_read(zipper) do
      case Zipper.node(zipper) do
        {{:., dot_meta, [receiver, :code]}, meta, args} ->
          replace_if_error(zipper, receiver, {{:., dot_meta, [receiver, :type]}, meta, args})

        # `error[:code]` and `error["code"]`.
        {{:., _, [Access, :get]} = dot, meta, [receiver, key]} ->
          case rename_key(key) do
            :error -> zipper
            {:ok, renamed} -> replace_if_error(zipper, receiver, {dot, meta, [receiver, renamed]})
          end

        # `Map.get(error, :code)` and the rest of the accessor family.
        {{:., _, [{:__aliases__, _, [:Map]}, function]} = dot, meta, [receiver, key | rest]}
        when function in @map_accessors ->
          case rename_key(key) do
            :error ->
              zipper

            {:ok, renamed} ->
              replace_if_error(zipper, receiver, {dot, meta, [receiver, renamed | rest]})
          end

        _other ->
          zipper
      end
    end

    defp replace_if_error(zipper, receiver, replacement) do
      if error_variable?(receiver) do
        Zipper.replace(zipper, replacement)
      else
        zipper
      end
    end

    # Sourceror wraps a literal in a `:__block__` node carrying its formatting,
    # so the atom and the string forms are rewritten through that wrapper.
    defp rename_key({:__block__, meta, [:code]}), do: {:ok, {:__block__, meta, [:type]}}
    defp rename_key({:__block__, meta, ["code"]}), do: {:ok, {:__block__, meta, ["type"]}}
    defp rename_key(_other), do: :error

    defp error_variable?({name, _meta, context}) when is_atom(name) and is_atom(context) do
      name = Atom.to_string(name)

      name in @error_names or String.ends_with?(name, @error_name_suffix)
    end

    defp error_variable?(_node), do: false
  end
else
  defmodule Mix.Tasks.AshIntrospection.Upgrade do
    @moduledoc false

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_introspection.upgrade' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
