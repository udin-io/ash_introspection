# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.Errors do
  @moduledoc """
  Central error processing module for RPC operations.

  Handles error transformation, unwrapping, and formatting for clients.
  Uses the AshIntrospection.Rpc.Error protocol to extract minimal information from exceptions.

  This is a shared module used by both AshTypescript and AshKotlinMultiplatform.
  Language-specific behavior is configured via the config parameter.
  """

  require Logger

  alias AshIntrospection.Rpc.DefaultErrorHandler
  alias AshIntrospection.Rpc.Error, as: ErrorProtocol

  @type config :: %{
          optional(:output_field_formatter) => atom(),
          optional(:rpc_dsl_section) => atom(),
          optional(:field_formatter_module) => module(),
          optional(:format_field_for_client) => (atom(), module() | nil, atom() -> String.t())
        }

  @doc """
  Transforms errors into standardized RPC error responses.

  Processes errors through the following pipeline:
  1. Convert to Ash error class using Ash.Error.to_error_class
  2. Unwrap nested error structures
  3. Transform via Error protocol
  4. Apply resource-level error handler (if configured)
  5. Apply domain-level error handler (if configured)
  6. Interpolate variables into messages

  ## Parameters

  - `errors` - The error(s) to transform
  - `domain` - The domain module (optional)
  - `resource` - The resource module (optional)
  - `action` - The action name (optional)
  - `context` - Additional context map
  - `config` - Language-specific configuration (see type definition)
  """
  @spec to_errors(term(), module() | nil, module() | nil, atom() | nil, map(), config()) ::
          list(map())
  def to_errors(errors, domain \\ nil, resource \\ nil, action \\ nil, context \\ %{}, config \\ %{})

  def to_errors(errors, domain, resource, action, context, config) do
    ash_error = Ash.Error.to_error_class(errors)

    ash_error
    |> unwrap_errors()
    |> Enum.map(&process_single_error(&1, domain, resource, action, context, config))
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&format_error_field_names(&1, resource, config))
  end

  @doc """
  Unwraps nested error structures from Ash error classes.
  """
  @spec unwrap_errors(term()) :: list(term())
  def unwrap_errors(%{errors: errors}) when is_list(errors) do
    Enum.flat_map(errors, &unwrap_errors/1)
  end

  def unwrap_errors(%{errors: error}) when not is_list(error) do
    unwrap_errors([error])
  end

  def unwrap_errors(errors) when is_list(errors) do
    Enum.flat_map(errors, &unwrap_errors/1)
  end

  def unwrap_errors(error) do
    [error]
  end

  defp process_single_error(error, domain, resource, _action, context, config) do
    # Check if we should show raised errors
    show_raised_errors? = get_show_raised_errors?(domain, config)

    transformed_error =
      if show_raised_errors? and is_exception(error) do
        # When show_raised_errors? is true, always expose the actual exception message
        %{
          message: Exception.message(error),
          short_message: error.__struct__ |> Module.split() |> List.last(),
          code: Macro.underscore(error.__struct__ |> Module.split() |> List.last()),
          vars: %{},
          fields: [],
          path: Map.get(error, :path, [])
        }
      else
        # Use protocol implementation or fallback
        if ErrorProtocol.impl_for(error) do
          try do
            ErrorProtocol.to_error(error)
          rescue
            e ->
              Logger.warning("""
              Failed to transform error via protocol: #{inspect(e)}
              Original error: #{inspect(error)}
              """)

              fallback_error_response(error, false)
          end
        else
          handle_unimplemented_error(error, false)
        end
      end

    # Apply resource-level error handler if configured
    transformed_error =
      if resource && function_exported?(resource, :handle_rpc_error, 2) do
        apply_error_handler(
          {resource, :handle_rpc_error, []},
          transformed_error,
          context
        )
      else
        transformed_error
      end

    # Apply domain-level error handler if configured
    transformed_error =
      if domain do
        handler = get_domain_error_handler(domain, config)
        apply_error_handler(handler, transformed_error, context)
      else
        transformed_error
      end

    # Apply default error handler for variable interpolation
    DefaultErrorHandler.handle_error(transformed_error, context)
  end

  defp apply_error_handler({module, function, args}, error, context) do
    case apply(module, function, [error, context | args]) do
      nil -> nil
      handled -> handled
    end
  rescue
    e ->
      Logger.warning("""
      Error handler failed: #{inspect(e)}
      Handler: #{inspect({module, function, args})}
      Original error: #{inspect(error)}
      """)

      error
  end

  defp get_domain_error_handler(domain, config) do
    rpc_dsl_section = Map.get(config, :rpc_dsl_section, :typescript_rpc)

    # Check if domain has RPC configuration with error handler
    with true <- function_exported?(domain, :spark_dsl_config, 0),
         {:ok, handler} <-
           Spark.Dsl.Extension.fetch_opt(domain, [rpc_dsl_section], :error_handler) do
      case handler do
        {module, function, args} -> {module, function, args}
        module when is_atom(module) -> {module, :handle_error, []}
        _ -> {DefaultErrorHandler, :handle_error, []}
      end
    else
      _ ->
        {DefaultErrorHandler, :handle_error, []}
    end
  end

  defp get_show_raised_errors?(nil, _config), do: false

  defp get_show_raised_errors?(domain, config) do
    rpc_dsl_section = Map.get(config, :rpc_dsl_section, :typescript_rpc)

    with true <- function_exported?(domain, :spark_dsl_config, 0),
         {:ok, show_raised_errors?} <-
           Spark.Dsl.Extension.fetch_opt(domain, [rpc_dsl_section], :show_raised_errors?) do
      show_raised_errors?
    else
      _ -> false
    end
  end

  defp handle_unimplemented_error(error, _show_raised_errors?) when is_exception(error) do
    uuid = Ash.UUID.generate()

    # Log the full error details for debugging (only visible server-side)
    Logger.warning("""
    Unhandled error in RPC (no protocol implementation).
    Error ID: #{uuid}
    Error type: #{inspect(error.__struct__)}
    Message: #{Exception.message(error)}

    To handle this error type, implement the AshIntrospection.Rpc.Error protocol:

    defimpl AshIntrospection.Rpc.Error, for: #{inspect(error.__struct__)} do
      def to_error(error) do
        %{
          message: error.message,
          short_message: "Error description",
          code: "error_code",
          vars: %{},
          fields: [],
          path: error.path || []
        }
      end
    end
    """)

    %{
      message: "Something went wrong. Unique error id: #{uuid}",
      short_message: "Internal error",
      code: "internal_error",
      vars: %{},
      fields: [],
      path: Map.get(error, :path, []),
      error_id: uuid
    }
  end

  defp handle_unimplemented_error(error, _show_raised_errors?) do
    uuid = Ash.UUID.generate()

    Logger.warning("""
    Unhandled non-exception error in RPC.
    Error ID: #{uuid}
    Error: #{inspect(error)}
    """)

    %{
      message: "Something went wrong. Unique error id: #{uuid}",
      short_message: "Internal error",
      code: "internal_error",
      vars: %{},
      fields: [],
      path: [],
      error_id: uuid
    }
  end

  defp fallback_error_response(error, _show_raised_errors?) when is_exception(error) do
    %{
      message: "something went wrong",
      short_message: "Error",
      code: "error",
      vars: %{},
      fields: [],
      path: Map.get(error, :path, [])
    }
  end

  defp fallback_error_response(_error, _show_raised_errors?) do
    %{
      message: "something went wrong",
      short_message: "Error",
      code: "error",
      vars: %{},
      fields: [],
      path: []
    }
  end

  # Formats field names in error structures for client consumption.
  # Applies resource-level field_names mappings (if resource is known) and output formatter.
  defp format_error_field_names(error, resource, config) when is_map(error) do
    formatter = Map.get(config, :output_field_formatter, :camel_case)
    field_formatter_module = Map.get(config, :field_formatter_module, AshIntrospection.FieldFormatter)

    error
    |> format_fields_array(resource, formatter, field_formatter_module, config)
    |> format_path_array(formatter, field_formatter_module)
    |> format_vars_field(resource, formatter, field_formatter_module, config)
  end

  defp format_error_field_names(error, _resource, _config), do: error

  defp format_fields_array(%{fields: fields} = error, resource, formatter, field_formatter_module, config)
       when is_list(fields) do
    format_field_for_client = Map.get(config, :format_field_for_client)

    formatted_fields =
      Enum.map(fields, fn field ->
        if format_field_for_client do
          format_field_for_client.(field, resource, formatter)
        else
          apply(field_formatter_module, :format_field_name, [to_string(field), formatter])
        end
      end)

    %{error | fields: formatted_fields}
  end

  defp format_fields_array(error, _resource, _formatter, _field_formatter_module, _config), do: error

  defp format_path_array(%{path: path} = error, formatter, field_formatter_module) when is_list(path) do
    # Path segments use simple formatting (no resource-level mappings)
    formatted_path =
      Enum.map(path, fn
        segment when is_atom(segment) ->
          apply(field_formatter_module, :format_field_name, [to_string(segment), formatter])

        segment when is_binary(segment) ->
          apply(field_formatter_module, :format_field_name, [segment, formatter])

        other ->
          other
      end)

    %{error | path: formatted_path}
  end

  defp format_path_array(error, _formatter, _field_formatter_module), do: error

  defp format_vars_field(%{vars: vars} = error, resource, formatter, field_formatter_module, config)
       when is_map(vars) do
    format_field_for_client = Map.get(config, :format_field_for_client)

    formatted_vars =
      Enum.into(vars, %{}, fn
        {:field, field} ->
          formatted =
            if format_field_for_client do
              format_field_for_client.(field, resource, formatter)
            else
              apply(field_formatter_module, :format_field_name, [to_string(field), formatter])
            end

          {:field, formatted}

        other ->
          other
      end)

    %{error | vars: formatted_vars}
  end

  defp format_vars_field(error, _resource, _formatter, _field_formatter_module, _config), do: error
end
