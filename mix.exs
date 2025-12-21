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
      docs: docs(),
      name: "AshIntrospection",
      description: @description,
      source_url: "https://github.com/udin-io/ash_introspection",
      homepage_url: "https://hexdocs.pm/ash_introspection",
      consolidate_protocols: Mix.env() != :test
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: [
        {"README.md", title: "Home"},
        {"CHANGELOG.md", title: "Changelog"}
      ],
      groups_for_modules: [
        "Type System": [
          AshIntrospection.TypeSystem.Introspection,
          AshIntrospection.TypeSystem.ResourceFields
        ],
        "RPC Pipeline": [
          AshIntrospection.Rpc.Pipeline,
          AshIntrospection.Rpc.Request,
          AshIntrospection.Rpc.ValueFormatter,
          AshIntrospection.Rpc.ResultProcessor,
          AshIntrospection.Rpc.FieldExtractor
        ],
        "Field Processing": [
          AshIntrospection.Rpc.FieldProcessing.Atomizer,
          AshIntrospection.Rpc.FieldProcessing.FieldSelector,
          AshIntrospection.Rpc.FieldProcessing.Validation
        ],
        "Error Handling": [
          AshIntrospection.Rpc.Error,
          AshIntrospection.Rpc.ErrorBuilder,
          AshIntrospection.Rpc.Errors,
          AshIntrospection.Rpc.DefaultErrorHandler
        ],
        "Code Generation": [
          AshIntrospection.Codegen.TypeDiscovery,
          AshIntrospection.Codegen.ActionIntrospection,
          AshIntrospection.Codegen.ValidationErrorTypes
        ],
        Utilities: [
          AshIntrospection.FieldFormatter,
          AshIntrospection.Helpers
        ]
      ]
    ]
  end

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
        "GitHub" => "https://github.com/udin-io/ash_introspection",
        "Discord" => "https://discord.gg/HTHRaaVPUc",
        "Website" => "https://ash-hq.org"
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
