# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.Request do
  @moduledoc """
  Request data structure for the RPC pipeline.

  Contains all parsed and validated request data needed for Ash execution.
  Immutable structure that flows through the pipeline stages.

  This is a shared module used by both AshTypescript and AshKotlinMultiplatform.
  """

  @type t :: %__MODULE__{
          domain: module(),
          resource: module(),
          action: map(),
          rpc_action: map(),
          tenant: term(),
          actor: term(),
          context: map(),
          select: list(atom()),
          load: list(),
          extraction_template: map(),
          input: map(),
          identity: term(),
          get_by: map() | nil,
          filter: map() | nil,
          sort: list() | nil,
          pagination: map() | nil,
          show_metadata: list(atom())
        }

  defstruct [
    :domain,
    :resource,
    :action,
    :rpc_action,
    :tenant,
    :actor,
    :context,
    :select,
    :load,
    :extraction_template,
    :input,
    :identity,
    :get_by,
    :filter,
    :sort,
    :pagination,
    show_metadata: []
  ]

  @doc """
  Creates a new Request with validated parameters.

  ## Examples

      iex> AshIntrospection.Rpc.Request.new(%{domain: MyApp.Domain, resource: MyApp.Todo})
      %AshIntrospection.Rpc.Request{domain: MyApp.Domain, resource: MyApp.Todo, ...}
  """
  @spec new(map()) :: t()
  def new(params) when is_map(params) do
    struct(__MODULE__, params)
  end
end
