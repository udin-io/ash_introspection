# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Test.ManifestFixture do
  @moduledoc """
  One `%Ash.Info.Manifest{}` built from the test resources, for the tests that
  need `AshIntrospection.ResourceInfo` to read from a manifest.

  ## Why a static fixture and not upstream's inline modules

  `AshTypescript.Manifest.verify_for_domains/2` compiles a throwaway manifest
  module per test, named deterministically with `:erlang.phash2/1`. That
  pattern needs a manifest **DSL** to compile against, and issue #23 puts that
  DSL in the consumer, not here — this library ships none, which is the
  recorded reason #26 was declined. Porting `verify_for_domains/2` in stage 1
  would mean building the one thing stage 1 is not building.

  So the manifest comes straight from `Ash.Info.Manifest.generate/1`, ash's own
  generator, against the resources in `test/support/`. That exercises the real
  struct rather than a hand-written imitation of it, and it needs no new
  library surface.

  ## Why the entrypoints are explicit

  `Ash.Info.Manifest.Generator.generate/1` requires `:otp_app`, but when
  `:action_entrypoints` is given it builds its resource map from those tuples
  and never reads the discovered domains
  (`deps/ash/lib/ash/info/manifest/generator.ex:206`). That matters here: this
  library's test domains are deliberately unregistered — `config/test.exs` sets
  `config :ash, :validate_domain_config_inclusion?, false` so they compile
  without being listed under `ash_domains` (#39) — so an `otp_app`-only scan
  finds nothing.

  ## What is deliberately left out

  `AshIntrospection.Test.EmbeddedAddress` is reachable from no entrypoint
  below, so the manifest does not carry it while
  `Ash.Resource.Info.resource?/1` still answers `true` for it. That gap is the
  fixture for the `runtime_resource?/2` versus `declared_resource?/2`
  divergence — see `test/ash_introspection/resource_info_test.exs`.
  """

  alias AshIntrospection.Manifest.Custom
  alias AshIntrospection.Manifest.Decorator
  alias AshIntrospection.Test

  @default_namespace Custom.default_namespace()

  @entrypoints [
    {Test.User, :read},
    {Test.User, :create},
    {Test.User, :update},
    {Test.Address, :read},
    {Test.Account, :read},
    {Test.Account, :get_account},
    {Test.Account, :create},
    {Test.Account, :update},
    {Test.Document, :read},
    {Test.Document, :audited},
    {Test.Document, :attach},
    {Test.Document, :render},
    {Test.Ledger, :read},
    {Test.Ledger, :ping},
    {Test.LedgerEntry, :list_entries},
    {Test.LedgerEntry, :paged_entries},
    {Test.LedgerEntry, :get_entry},
    {Test.AuditedRecord, :read_with_metadata},
    {Test.LoadRestrictions.Article, :read},
    {Test.LoadRestrictions.Author, :read},
    {Test.LoadRestrictions.Comment, :read},
    {Test.RelPagination.Library, :read},
    {Test.Dossier, :read}
  ]

  @doc "The `{resource, action}` pairs the fixture manifest is generated from."
  @spec entrypoints() :: [{module(), atom()}]
  def entrypoints, do: @entrypoints

  @doc """
  The resource modules that appear in the fixture manifest's `resources` list.

  Read off the generated manifest rather than listed by hand, so a fixture
  resource gaining or losing reachability cannot leave this stale.
  """
  @spec resource_modules() :: [module()]
  def resource_modules, do: Enum.map(manifest().resources, & &1.module)

  @doc "The embedded resource modules the fixture manifest carries as types."
  @spec embedded_modules() :: [module()]
  def embedded_modules do
    manifest().types
    |> Enum.filter(&(&1.kind == :embedded_resource))
    |> Enum.map(& &1.module)
  end

  @doc """
  The fixture manifest, generated once per VM.

  Generation walks the whole reachable type graph, so it is cached in
  `:persistent_term` rather than repeated for each of the tests that ask.
  """
  @spec manifest() :: Ash.Info.Manifest.t()
  def manifest do
    cached(__MODULE__, fn ->
      {:ok, manifest} =
        Ash.Info.Manifest.generate(
          otp_app: :ash_introspection,
          action_entrypoints: @entrypoints
        )

      manifest
    end)
  end

  @doc """
  The fixture manifest decorated by `AshIntrospection.Manifest.Decorator`.

  Cached per VM like `manifest/0`, and only for the default namespace with an
  empty config — a test that passes either builds its own, because those are
  the arguments it is varying.
  """
  @spec decorated(atom(), map() | nil) :: Ash.Info.Manifest.t()
  def decorated(namespace \\ Custom.default_namespace(), config \\ nil)

  def decorated(@default_namespace, nil) do
    cached({__MODULE__, :decorated}, fn ->
      Decorator.decorate(manifest(), @default_namespace, decorator_config())
    end)
  end

  def decorated(namespace, config),
    do: Decorator.decorate(manifest(), namespace, config || decorator_config())

  @doc """
  The decorator config the fixture uses.

  Only `:entrypoint_name` is set, because the decorator has no default for it:
  a client-facing action name is the consumer's to choose, and an action name
  alone is not unique across resources. The fixture qualifies each with its
  resource so `:read` on four resources gets four names.
  """
  @spec decorator_config() :: map()
  def decorator_config, do: %{entrypoint_name: &entrypoint_name/2}

  @doc "The fixture's client-facing name for `{resource, action}`."
  @spec entrypoint_name(module(), atom()) :: String.t()
  def entrypoint_name(resource, action) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> Kernel.<>("_#{action}")
    |> AshIntrospection.FieldFormatter.format_field_name(:camel_case)
  end

  @doc "The fixture manifest with its lookup maps prepared."
  @spec source() :: AshIntrospection.ResourceInfo.Source.t()
  def source, do: AshIntrospection.ResourceInfo.prepare(manifest())

  @doc "The decorated fixture manifest with its lookup maps prepared."
  @spec decorated_source() :: AshIntrospection.ResourceInfo.Source.t()
  def decorated_source, do: AshIntrospection.ResourceInfo.prepare(decorated())

  @doc "A config map carrying the prepared, undecorated fixture manifest."
  @spec config(map()) :: map()
  def config(extra \\ %{}), do: Map.put(extra, :manifest, source())

  @doc "A config map carrying the prepared, decorated fixture manifest."
  @spec decorated_config(map()) :: map()
  def decorated_config(extra \\ %{}), do: Map.put(extra, :manifest, decorated_source())

  defp cached(key, build) do
    case :persistent_term.get(key, nil) do
      nil ->
        value = build.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end
end
