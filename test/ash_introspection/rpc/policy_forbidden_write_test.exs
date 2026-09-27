# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.PolicyForbiddenWriteTest do
  @moduledoc """
  An update or destroy that changes zero rows tells the client why: the record
  exists but the actor may not touch it (`forbidden`), or no such record exists
  (`not_found`). Reads keep hiding records the actor may not see.
  """
  use ExUnit.Case, async: false

  alias AshIntrospection.Manifest.Custom
  alias AshIntrospection.ResourceInfo
  alias AshIntrospection.Rpc.ErrorBuilder
  alias AshIntrospection.Rpc.Pipeline
  alias AshIntrospection.Rpc.Request
  alias AshIntrospection.Test.ManifestFixture
  alias AshIntrospection.Test.Policy.Domain
  alias AshIntrospection.Test.Policy.LooseNote
  alias AshIntrospection.Test.Policy.Note
  alias AshIntrospection.Test.Policy.TenantNote

  @owner %{id: "owner-1"}
  @stranger %{id: "owner-2"}
  @missing_id "00000000-0000-0000-0000-000000000000"

  setup do
    note = create_note(%{title: "mine", owner_id: @owner.id})
    %{note: note}
  end

  describe "a record another owner holds" do
    test "destroy returns one forbidden error", %{note: note} do
      assert [error] = errors!(execute(write(:destroy, note.id, @stranger)))
      assert error.type == "forbidden"
      assert error.message == "forbidden"
      assert error.vars == %{}
    end

    test "update returns one forbidden error", %{note: note} do
      assert [error] = errors!(execute(write(:update, note.id, @stranger, %{title: "theirs"})))
      assert error.type == "forbidden"
      assert error.message == "forbidden"
    end

    test "leaves the record unchanged", %{note: note} do
      execute(write(:update, note.id, @stranger, %{title: "theirs"}))
      execute(write(:destroy, note.id, @stranger))

      assert {:ok, %{title: "mine"}} = Ash.get(Note, note.id, actor: @owner)
    end

    test "a list read by the stranger returns no rows", %{note: note} do
      assert {:ok, notes} = execute(read(:read, @stranger))
      refute Enum.any?(notes, &(&1.id == note.id))
    end

    test "a get_by read by the stranger returns not_found", %{note: note} do
      request = %{read(:read, @stranger) | get_by: %{id: note.id}}
      assert [%{type: "not_found"}] = errors!(execute(request))
    end
  end

  describe "the owner's own record" do
    test "destroy succeeds with the record", %{note: note} do
      assert {:ok, %{id: id}} = execute(write(:destroy, note.id, @owner))
      assert id == note.id
    end

    test "update succeeds with the record", %{note: note} do
      assert {:ok, %{title: "renamed"}} =
               execute(write(:update, note.id, @owner, %{title: "renamed"}))
    end
  end

  describe "a record that does not exist" do
    test "destroy returns not_found" do
      assert [%{type: "not_found"}] = errors!(execute(write(:destroy, @missing_id, @owner)))
    end

    test "destroy of an identity that is not a valid key returns not_found" do
      assert [%{type: "not_found"}] = errors!(execute(write(:destroy, "not-a-uuid", @owner)))
    end

    test "update returns not_found" do
      assert [%{type: "not_found"}] =
               errors!(execute(write(:update, @missing_id, @owner, %{title: "x"})))
    end

    test "a stranger's destroy returns not_found while another owner's row exists" do
      assert [%{type: "not_found"}] = errors!(execute(write(:destroy, @missing_id, @stranger)))
    end

    test "a stranger's update returns not_found while another owner's row exists" do
      assert [%{type: "not_found"}] =
               errors!(execute(write(:update, @missing_id, @stranger, %{title: "x"})))
    end
  end

  describe "a record the rpc action's read_action hides" do
    setup do
      %{archived: create_note(%{title: "old", owner_id: @owner.id, archived: true})}
    end

    test "destroy returns not_found, not forbidden", %{archived: archived} do
      request = write(:destroy, archived.id, @owner, %{}, read_action: :active)
      assert [%{type: "not_found"}] = errors!(execute(request))
    end

    test "destroy by a stranger returns not_found", %{archived: archived} do
      request = write(:destroy, archived.id, @stranger, %{}, read_action: :active)
      assert [%{type: "not_found"}] = errors!(execute(request))
    end

    test "update by a stranger returns not_found", %{archived: archived} do
      request = write(:update, archived.id, @stranger, %{title: "x"}, read_action: :active)
      assert [%{type: "not_found"}] = errors!(execute(request))
    end

    test "update returns not_found, not forbidden", %{archived: archived} do
      request = write(:update, archived.id, @owner, %{title: "x"}, read_action: :active)
      assert [%{type: "not_found"}] = errors!(execute(request))
    end
  end

  describe "a record of another tenant" do
    setup do
      tenant_note =
        TenantNote
        |> Ash.Changeset.for_create(
          :create,
          %{title: "a's", org_id: "org-a", owner_id: @owner.id},
          tenant: "org-a"
        )
        |> Ash.create!()

      %{tenant_note: tenant_note}
    end

    test "destroy by its owner returns not_found", %{tenant_note: tenant_note} do
      request = %{tenant_write(:destroy, tenant_note.id, @owner) | tenant: "org-b"}
      assert [%{type: "not_found"}] = errors!(execute(request))
    end

    test "destroy by a stranger returns not_found", %{tenant_note: tenant_note} do
      request = %{tenant_write(:destroy, tenant_note.id, @stranger) | tenant: "org-b"}
      assert [%{type: "not_found"}] = errors!(execute(request))
    end

    test "update by a stranger returns not_found", %{tenant_note: tenant_note} do
      request = %{
        tenant_write(:update, tenant_note.id, @stranger, %{title: "b's"})
        | tenant: "org-b"
      }

      assert [%{type: "not_found"}] = errors!(execute(request))
    end
  end

  describe "a write whose change filter skips the owner's row" do
    setup do
      %{archived: create_note(%{title: "old", owner_id: @owner.id, archived: true})}
    end

    test "update returns not_found and leaves the row", %{archived: archived} do
      request = write(:rename_live, archived.id, @owner, %{title: "x"})
      assert [%{type: "not_found"}] = errors!(execute(request))
      assert {:ok, %{title: "old"}} = Ash.get(Note, archived.id, actor: @owner)
    end

    test "destroy returns not_found", %{archived: archived} do
      assert [%{type: "not_found"}] = errors!(execute(write(:purge_live, archived.id, @owner)))
    end

    test "another owner still gets forbidden", %{archived: archived} do
      request = write(:rename_live, archived.id, @stranger, %{title: "x"})
      assert [%{type: "forbidden"}] = errors!(execute(request))
    end

    # Under `authorize_changeset_with: :filter` a write-policy denial also
    # leaves a readable row unwritten, so the two causes look the same and the
    # answer stays `forbidden`. Risk T7 in `docs/risks.md` records it.
    test "a data layer on the :filter strategy answers forbidden", %{archived: archived} do
      request = write(:rename_live, archived.id, @owner, %{title: "x"})
      config = %{manifest: ResourceInfo.prepare(filter_strategy_manifest())}

      assert {:error, errors} = Pipeline.execute_ash_action(request, config)
      assert [%{type: "forbidden"}] = ErrorBuilder.build_error_response(errors)
    end
  end

  describe "an rpc action with no identity" do
    test "a zero-row destroy returns not_found while another owner's row exists", %{note: note} do
      request = %{write(:destroy, note.id, @stranger, %{}, identities: []) | identity: nil}
      assert [%{type: "not_found"}] = errors!(execute(request))
    end

    test "a zero-row update returns not_found while another owner's row exists", %{note: note} do
      request = %{
        write(:update, note.id, @stranger, %{title: "x"}, identities: [])
        | identity: nil
      }

      assert [%{type: "not_found"}] = errors!(execute(request))
    end
  end

  describe "a resource that names no domain of its own" do
    test "a zero-row destroy returns not_found" do
      assert [%{type: "not_found"}] = errors!(execute(loose_write(:destroy)))
    end

    test "a zero-row update returns not_found" do
      assert [%{type: "not_found"}] = errors!(execute(loose_write(:update, %{title: "x"})))
    end
  end

  describe "with policy breakdowns shown" do
    setup do
      previous = Application.get_env(:ash_introspection, :policies)
      Application.put_env(:ash_introspection, :policies, show_policy_breakdowns?: true)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_introspection, :policies, previous),
          else: Application.delete_env(:ash_introspection, :policies)
      end)
    end

    test "a forbidden destroy returns plain forbidden, with no breakdown", %{note: note} do
      assert [error] = errors!(execute(write(:destroy, note.id, @stranger)))
      assert error.type == "forbidden"
      assert error.message == "forbidden"
    end

    test "a forbidden update returns plain forbidden, with no breakdown", %{note: note} do
      assert [error] = errors!(execute(write(:update, note.id, @stranger, %{title: "x"})))
      assert error.message == "forbidden"
    end

    test "a policy error Ash built keeps its breakdown" do
      memo =
        AshIntrospection.Test.Policy.Memo
        |> Ash.Changeset.for_create(:create, %{
          slug: "m-#{System.unique_integer()}",
          body: "b",
          owner_id: "o1"
        })
        |> Ash.create!()

      request = %{
        write(:destroy, memo.id, %{id: "o2"})
        | resource: AshIntrospection.Test.Policy.Memo,
          action: Ash.Resource.Info.action(AshIntrospection.Test.Policy.Memo, :destroy),
          select: [:id],
          extraction_template: [:id]
      }

      assert [error] = errors!(execute(request))
      assert error.message =~ "Policy Breakdown"
    end
  end

  defp execute(request),
    do: Pipeline.execute_ash_action(request, ManifestFixture.decorated_config())

  defp errors!({:error, errors}), do: ErrorBuilder.build_error_response(errors)

  defp filter_strategy_manifest do
    namespace = Custom.default_namespace()
    manifest = ManifestFixture.decorated()

    resources =
      Enum.map(manifest.resources, fn
        %{module: Note} = resource ->
          put_in(resource.custom[namespace][:authorize_bulk_strategy], :filter)

        resource ->
          resource
      end)

    %{manifest | resources: resources}
  end

  defp create_note(attrs) do
    Note
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!()
  end

  defp write(action, id, actor, input \\ %{}, rpc_opts \\ []) do
    Request.new(%{
      domain: Domain,
      resource: Note,
      action: Ash.Resource.Info.action(Note, action),
      rpc_action: Map.new(Keyword.merge([identities: [:_primary_key]], rpc_opts)),
      input: input,
      context: %{},
      actor: actor,
      select: [:id, :title],
      load: [],
      extraction_template: [:id, :title],
      identity: id
    })
  end

  defp tenant_write(action, id, actor, input \\ %{}) do
    Request.new(%{
      domain: Domain,
      resource: TenantNote,
      action: Ash.Resource.Info.action(TenantNote, action),
      rpc_action: %{identities: [:_primary_key]},
      input: input,
      context: %{},
      actor: actor,
      select: [:id, :title],
      load: [],
      extraction_template: [:id, :title],
      identity: id
    })
  end

  defp loose_write(action, input \\ %{}) do
    Request.new(%{
      domain: Domain,
      resource: LooseNote,
      action: Ash.Resource.Info.action(LooseNote, action),
      rpc_action: %{identities: [:_primary_key]},
      input: input,
      context: %{},
      actor: nil,
      select: [:id, :title],
      load: [],
      extraction_template: [:id, :title],
      identity: @missing_id
    })
  end

  defp read(action, actor) do
    Request.new(%{
      domain: Domain,
      resource: Note,
      action: Ash.Resource.Info.action(Note, action),
      rpc_action: %{},
      input: %{},
      context: %{},
      actor: actor,
      select: [:id, :title],
      load: [],
      extraction_template: [:id, :title]
    })
  end
end
