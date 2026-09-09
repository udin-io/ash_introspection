# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defprotocol AshIntrospection.Rpc.Error do
  @moduledoc """
  Protocol for extracting minimal information from exceptions for RPC responses.

  Similar to AshGraphql.Error, this protocol transforms various error types into
  a standardized format with only the essential information needed by clients.

  This is a shared protocol used by both AshTypescript and AshKotlinMultiplatform.

  ## Error Format

  Each implementation should return a map with these fields:
  - `:message` - The full error message (may contain template variables like %{key})
  - `:short_message` - A concise version of the message
  - `:type` - A machine-readable error type (e.g., "invalid_changes", "not_found")
  - `:vars` - A map of variables to interpolate into messages
  - `:fields` - A list of affected field names (for field-level errors)
  - `:path` - The path to the error location in the data structure
  - `:details` - An optional map with extra details

  ## Example Implementation

      defimpl AshIntrospection.Rpc.Error, for: MyApp.CustomError do
        def to_error(error) do
          %{
            message: error.message,
            short_message: "Custom error occurred",
            type: "custom_error",
            vars: %{detail: error.detail},
            fields: [],
            path: error.path || []
          }
        end
      end
  """

  @doc """
  Transforms an exception into a minimal error representation for RPC responses.
  """
  @spec to_error(Exception.t()) :: map()
  def to_error(exception)
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Changes.InvalidChanges do
  def to_error(error) do
    %{
      message: Map.get(error, :message) || Exception.message(error),
      short_message: "Invalid changes",
      vars: Map.new(error.vars || []),
      type: "invalid_changes",
      fields: List.wrap(error.fields),
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Query.InvalidQuery do
  def to_error(error) do
    %{
      message: Map.get(error, :message) || Exception.message(error),
      short_message: "Invalid query",
      vars: Map.new(error.vars || []),
      type: "invalid_query",
      fields: List.wrap(Map.get(error, :fields) || Map.get(error, :field)),
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Query.NotFound do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Not found",
      vars: Map.new(error.vars || []),
      type: "not_found",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Changes.Required do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Required field",
      vars: Map.new(error.vars || []) |> Map.put(:field, error.field),
      type: "required",
      fields: List.wrap(error.field),
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Query.Required do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Required field",
      vars: Map.new(error.vars || []) |> Map.put(:field, error.field),
      type: "required",
      fields: List.wrap(error.field),
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Forbidden.Policy do
  # `Exception.message/1` on this error renders the whole authorization report -
  # every policy, every check outcome, and the actor inspected in full - as soon
  # as the struct's `policy_breakdown?` flag is set, and Ash sets that flag from
  # its app-wide `:ash, :policies, show_policy_breakdowns?` toggle when the
  # exception is built. That toggle is a development aid, so reading it here
  # would let a stray dev setting open every RPC response in production.
  #
  # The breakdown is gated on this library's own config instead, which nothing
  # but an explicit decision turns on:
  #
  #     config :ash_introspection, :policies, show_policy_breakdowns?: true
  #
  # Mirrors ash_graphql's separate `show_policy_descriptions?` setting, and
  # ports upstream ash_typescript ef29ceb.
  def to_error(error) do
    message =
      if show_policy_breakdowns?() do
        Ash.Error.Forbidden.Policy.report(error, help_text?: false)
      else
        "forbidden"
      end

    %{
      message: message,
      short_message: "Forbidden",
      vars: Map.new(error.vars || []),
      type: "forbidden",
      fields: [],
      path: error.path || []
    }
  end

  defp show_policy_breakdowns? do
    :ash_introspection
    |> Application.get_env(:policies, [])
    |> Keyword.get(:show_policy_breakdowns?, false)
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Forbidden.ForbiddenField do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Forbidden field",
      vars: Map.new(error.vars || []) |> Map.put(:field, error.field),
      type: "forbidden_field",
      fields: List.wrap(error.field),
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Changes.InvalidAttribute do
  def to_error(error) do
    %{
      message: Map.get(error, :message) || Exception.message(error),
      short_message: "Invalid attribute",
      vars: Map.new(error.vars || []) |> Map.put(:field, error.field),
      type: "invalid_attribute",
      fields: List.wrap(error.field),
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Changes.InvalidArgument do
  def to_error(error) do
    %{
      message: Map.get(error, :message) || Exception.message(error),
      short_message: "Invalid argument",
      vars: Map.new(error.vars || []) |> Map.put(:field, Map.get(error, :field)),
      type: "invalid_argument",
      fields: List.wrap(Map.get(error, :field)),
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Query.InvalidArgument do
  def to_error(error) do
    %{
      message: Map.get(error, :message) || Exception.message(error),
      short_message: "Invalid argument",
      vars: Map.new(error.vars || []) |> Map.put(:field, Map.get(error, :field)),
      type: "invalid_argument",
      fields: List.wrap(Map.get(error, :field)),
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Page.InvalidKeyset do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Invalid keyset",
      vars: Map.new(error.vars || []),
      type: "invalid_keyset",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Query.InvalidPage do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Invalid pagination",
      vars: Map.new(error.vars || []),
      type: "invalid_page",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Invalid.InvalidPrimaryKey do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Invalid primary key",
      vars: Map.new(error.vars || []),
      type: "invalid_primary_key",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Query.ReadActionRequiresActor do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Authentication required",
      vars: Map.new(error.vars || []),
      type: "forbidden",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshIntrospection.Rpc.Error, for: Ash.Error.Unknown.UnknownError do
  # This is the bucket every unrecognised exception falls into, so its text is
  # whatever crashed - a database URL, a stack trace, a third-party library's
  # internals. The client gets a static message; the detail belongs in the logs.
  def to_error(error) do
    %{
      message: "Something went wrong",
      short_message: "Unknown error",
      vars: Map.new(error.vars || []),
      type: "unknown_error",
      fields: [],
      path: error.path || []
    }
  end
end

if Code.ensure_loaded?(AshAuthentication.Errors.AuthenticationFailed) do
  defimpl AshIntrospection.Rpc.Error, for: AshAuthentication.Errors.AuthenticationFailed do
    def to_error(error) do
      %{
        message: Map.get(error, :message) || "Authentication failed",
        short_message: "Authentication failed",
        vars: Map.new(error.vars || []),
        type: "authentication_failed",
        fields: List.wrap(Map.get(error, :field)),
        path: error.path || []
      }
    end
  end
end

if Code.ensure_loaded?(AshAuthentication.Errors.InvalidToken) do
  defimpl AshIntrospection.Rpc.Error, for: AshAuthentication.Errors.InvalidToken do
    def to_error(error) do
      %{
        message: Map.get(error, :message) || "Invalid token",
        short_message: "Invalid token",
        vars: Map.new(error.vars || []),
        type: "invalid_token",
        fields: [],
        path: error.path || []
      }
    end
  end
end
