# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.MixProject do
  use Mix.Project

  @version "0.2.0"

  @description """
  Shared core library for Ash interoperability with multiple languages.
  Provides type introspection, discovery, and RPC pipeline utilities.
  """

  def project do
    [
      app: :ash_introspection,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      deps: deps(),
      description: @description,
      source_url: "https://github.com/ash-project/ash_interop",
      homepage_url: "https://github.com/ash-project/ash_interop",
      consolidate_protocols: Mix.env() != :test
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      maintainers: [
        "Peter Shoukry"
      ],
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSES),
      links: %{
        "GitHub" => "https://github.com/ash-project/ash_interop",
        "Discord" => "https://discord.gg/HTHRaaVPUc",
        "Website" => "https://ash-hq.org",
        "Forum" => "https://elixirforum.com/c/elixir-framework-forums/ash-framework-forum"
      }
    ]
  end

  defp deps do
    [
      {:ash, ">= 3.7.0"},
      {:spark, ">= 2.3.14"},
      {:ex_doc, "~> 0.37", only: [:dev, :test], runtime: false}
    ]
  end
end
