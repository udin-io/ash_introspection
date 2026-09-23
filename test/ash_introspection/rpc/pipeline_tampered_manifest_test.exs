# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PipelineTamperedManifestTest do
  @moduledoc """
  Proves each request-path stage *reads* the manifest it was given, by lying to
  it.

  A parity test cannot prove this. `AshIntrospection.Manifest.Decorator`
  captures the live structs, so a manifest and live introspection agree by
  construction: the deleted `pipeline_manifest_parity_test.exs` passed whether
  or not a stage ever opened the manifest. The only way to separate the two
  sources is to make them disagree — tamper with one decorated payload and
  assert the response follows the tampered copy.
  `AshIntrospection.Test.ManifestTamper` writes the lies. This file is now the
  only proof that a stage reads the manifest at all.

  Each test varies the config of **one** stage and runs the others honestly, so
  a failure names the stage that stopped reading.

  Stage 2 is absent on purpose: it executes the Ash action, and its manifest
  reads (`primary_key/2`, `identity_keys/3`, `authorize_bulk_strategy/2`)
  already take the config map the caller passed, untouched.
  """
  use ExUnit.Case, async: true

  alias AshIntrospection.Manifest.Custom
  alias AshIntrospection.ResourceInfo
  alias AshIntrospection.Rpc.FieldProcessing.FieldSelector
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.Account
  alias AshIntrospection.Test.Dossier
  alias AshIntrospection.Test.DossierDomain
  alias AshIntrospection.Test.EmbeddedUnscoped
  alias AshIntrospection.Test.Ledger
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.ManifestTamper
  alias AshIntrospection.Test.RpcDomain
  alias AshIntrospection.Test.User

  @default_namespace Custom.default_namespace()
  @foreign_namespace :brief_test
  @embedding [0.5, -1.5, 2.25]

  defp prepared(manifest), do: %{manifest: ResourceInfo.prepare(manifest)}

  defp decorated, do: ManifestFixture.decorated()

  # ---------------------------------------------------------------------------
  # Requests and results
  # ---------------------------------------------------------------------------

  defp dossier_result do
    %Dossier{
      id: "11111111-1111-1111-1111-111111111111",
      label: "Quarterly",
      owner: %User{
        id: "22222222-2222-2222-2222-222222222222",
        name: "Ada",
        email: "ada@example.com",
        age: 36
      }
    }
  end

  defp dossier_request(template) do
    Request.new(%{
      domain: DossierDomain,
      resource: Dossier,
      action: Ash.Resource.Info.action(Dossier, :read),
      rpc_action: %{},
      input: %{},
      context: %{},
      select: [:id, :label, :owner],
      load: [],
      extraction_template: template,
      show_metadata: []
    })
  end

  # The template comes from an honest stage 1, so the stage under test is the
  # only one reading a tampered manifest.
  defp dossier_owner_template do
    {:ok, {_select, _load, template}} =
      FieldSelector.process(
        Dossier,
        :read,
        [:id, %{"owner" => ["id", "name"]}],
        ManifestFixture.decorated_config()
      )

    template
  end

  defp account_request(overrides) do
    %{
      domain: RpcDomain,
      resource: Account,
      action: Ash.Resource.Info.action(Account, :get_account),
      rpc_action: %{},
      input: %{},
      context: %{},
      select: [:id, :name, :email, :embedding],
      load: [],
      extraction_template: [:id, :name, :email, :embedding],
      show_metadata: []
    }
    |> Map.merge(overrides)
    |> Request.new()
  end

  defp create_account do
    suffix = System.unique_integer([:positive])

    Account
    |> Ash.Changeset.for_create(:create, %{
      name: "Tamper-#{suffix}",
      email: "tamper-#{suffix}@example.com",
      embedding: @embedding
    })
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # The tamper is not vacuous
  # ---------------------------------------------------------------------------

  describe "the fixture the tampering rests on" do
    test "carries both resources, decorated" do
      for module <- [Account, Dossier] do
        assert module in ManifestFixture.resource_modules(),
               "the fixture manifest does not carry #{inspect(module)}, so tampering with its " <>
                 "decoration changes nothing"

        assert {_resource, @default_namespace} =
                 ResourceInfo.decoration(module, decorated_config())
      end
    end

    test "a retype reaches the reader" do
      tampered =
        prepared(
          ManifestTamper.retype(
            decorated(),
            @default_namespace,
            Account,
            :embedding,
            Ash.Type.String
          )
        )

      assert ResourceInfo.attribute(Account, :embedding, tampered).type == Ash.Type.String

      assert ResourceInfo.attribute(Account, :embedding, decorated_config()).type ==
               Ash.Type.Vector
    end
  end

  # ---------------------------------------------------------------------------
  # Stage 1
  # ---------------------------------------------------------------------------

  describe "stage 1 — field selection" do
    test "a field the tampered manifest hides is refused" do
      tampered = prepared(ManifestTamper.hide(decorated(), @default_namespace, Account, :email))

      assert {:ok, {_select, _load, _template}} =
               FieldSelector.process(Account, :read, [:id, :email], decorated_config())

      assert {:error, {:unknown_field, :email, Account, []}} =
               FieldSelector.process(Account, :read, [:id, :email], tampered)
    end
  end

  # ---------------------------------------------------------------------------
  # Stage 3
  # ---------------------------------------------------------------------------

  describe "stage 3 — result processing" do
    test "a retyped struct attribute is extracted as the tampered type says" do
      request = dossier_request(dossier_owner_template())

      {:ok, honest} = Pipeline.process_result(dossier_result(), request, decorated_config())

      assert honest.owner == %{
               id: "22222222-2222-2222-2222-222222222222",
               name: "Ada"
             }

      tampered =
        prepared(
          ManifestTamper.retype(decorated(), @default_namespace, Dossier, :owner, Ash.Type.String)
        )

      {:ok, result} = Pipeline.process_result(dossier_result(), request, tampered)

      # `Ash.Type.String` gives stage 3 no fields to select against, so the
      # whole struct is normalized and the selection is not applied.
      assert result.owner.email == "ada@example.com"
      assert result.owner.age == 36
    end
  end

  # ---------------------------------------------------------------------------
  # Stage 4
  # ---------------------------------------------------------------------------

  describe "stage 4 — output formatting" do
    test "a retyped vector attribute is formatted as the tampered type says" do
      account = create_account()
      request = account_request(%{get_by: %{email: account.email}})

      {:ok, ash_result} = Pipeline.execute_ash_action(request, decorated_config())
      {:ok, processed} = Pipeline.process_result(ash_result, request, decorated_config())

      honest =
        Pipeline.format_output_with_request(
          %{success: true, data: processed},
          request,
          decorated_config()
        )

      assert honest["data"]["embedding"] == @embedding

      tampered =
        prepared(
          ManifestTamper.retype(
            decorated(),
            @default_namespace,
            Account,
            :embedding,
            Ash.Type.String
          )
        )

      response =
        Pipeline.format_output_with_request(%{success: true, data: processed}, request, tampered)

      # `Ash.Type.Vector` is the only reason a vector reaches the client as a
      # list of numbers. Told the attribute is a string, stage 4 hands back the
      # packed binary it was given.
      refute response["data"]["embedding"] == @embedding
      assert %{data: data, dimensions: 3} = response["data"]["embedding"]
      assert is_binary(data)
    end
  end

  # ---------------------------------------------------------------------------
  # Classification
  # ---------------------------------------------------------------------------

  describe "an embedded attribute the tampered manifest declares a resource" do
    test "stage 1 classifies it as the manifest says" do
      assert EmbeddedUnscoped in ManifestFixture.embedded_modules(),
             "the fixture manifest does not carry EmbeddedUnscoped as an embedded type"

      honest = decorated_config()
      tampered = prepared(ManifestTamper.declare_resource(decorated(), EmbeddedUnscoped))

      assert ResourceInfo.embedded?(EmbeddedUnscoped, honest)
      refute ResourceInfo.embedded?(EmbeddedUnscoped, tampered)

      # An embedded attribute demands a nested selection and accepts one.
      assert {:error, {:requires_field_selection, :embedded_resource, :trail, []}} =
               FieldSelector.process(Ledger, :read, [:id, :trail], honest)

      assert {:ok, {[:id, :trail], [], [:id, {:trail, [:note]}]}} =
               FieldSelector.process(Ledger, :read, [:id, %{"trail" => ["note"]}], honest)

      # Told it is a declared resource rather than an embedded one, stage 1
      # classifies it as a plain attribute: the flat select it refused is
      # allowed, and the nested selection it accepted is refused.
      assert {:ok, {[:id, :trail], [], [:id, :trail]}} =
               FieldSelector.process(Ledger, :read, [:id, :trail], tampered)

      assert {:error, {:field_does_not_support_nesting, :trail, []}} =
               FieldSelector.process(Ledger, :read, [:id, %{"trail" => ["note"]}], tampered)
    end
  end

  # ---------------------------------------------------------------------------
  # A foreign namespace
  # ---------------------------------------------------------------------------

  describe "a bare manifest decorated under a foreign namespace" do
    test "stage 3 reads the decoration `:manifest_namespace` names" do
      request = dossier_request(dossier_owner_template())

      tampered =
        ManifestFixture.decorated(@foreign_namespace)
        |> ManifestTamper.retype(@foreign_namespace, Dossier, :owner, Ash.Type.String)

      config = %{manifest: tampered, manifest_namespace: @foreign_namespace}

      {:ok, result} = Pipeline.process_result(dossier_result(), request, config)

      assert result.owner.email == "ada@example.com",
             "stage 3 read live: the namespace did not survive the config rebuild"
    end
  end

  defp decorated_config, do: ManifestFixture.decorated_config()
end
