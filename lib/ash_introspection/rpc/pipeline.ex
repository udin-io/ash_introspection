# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.Pipeline do
  @moduledoc """
  Language-agnostic four-stage RPC pipeline for Ash actions.

  Implements the core pipeline stages:
  1. parse_request/3 - Parse and validate input with fail-fast
  2. execute_ash_action/2 - Execute Ash operations
  3. process_result/3 - Apply field selection
  4. format_output/3 - Format for client consumption

  ## Configuration

  The pipeline is configured via a config map that provides all the
  language-specific behavior through callbacks:

  ```elixir
  %{
    input_field_formatter: :camel_case,
    output_field_formatter: :camel_case,
    field_names_callback: :interop_field_names,
    get_original_field_name: fn resource, client_key -> ... end,
    format_field_for_client: fn field_name, resource, formatter -> ... end,
    discover_action: fn otp_app, params -> ... end,
    not_found_error?: true
  }
  ```

  ## Usage

  Language-specific wrappers (e.g., AshTypescript.Rpc.Pipeline) should:
  1. Build the config map with their specific callbacks
  2. Call the shared pipeline functions with that config
  3. Handle any language-specific pre/post processing

  This allows each language generator to customize the behavior while
  sharing the core pipeline logic.
  """

  alias AshIntrospection.FieldFormatter
  alias AshIntrospection.Rpc.{Request, ResultProcessor, ValueFormatter}
  alias AshIntrospection.TypeSystem.Introspection

  @type config :: %{
          optional(:input_field_formatter) => atom(),
          optional(:output_field_formatter) => atom(),
          optional(:field_names_callback) => atom(),
          optional(:get_original_field_name) => (module(), String.t() -> atom() | nil),
          optional(:format_field_for_client) => (atom(), module() | nil, atom() -> String.t()),
          optional(:not_found_error?) => boolean()
        }

  # ---------------------------------------------------------------------------
  # Stage 2: Execute Ash Action
  # ---------------------------------------------------------------------------

  @doc """
  Stage 2: Execute Ash action using the parsed request.

  Builds the appropriate Ash query/changeset and executes it.
  Returns the raw Ash result for further processing.
  """
  @spec execute_ash_action(Request.t(), config()) :: {:ok, term()} | {:error, term()}
  def execute_ash_action(%Request{} = request, config \\ %{}) do
    opts = [
      actor: request.actor,
      tenant: request.tenant,
      context: request.context
    ]

    result =
      case request.action.type do
        :read ->
          execute_read_action(request, opts, config)

        :create ->
          execute_create_action(request, opts)

        :update ->
          execute_update_action(request, opts)

        :destroy ->
          execute_destroy_action(request, opts)

        :action ->
          execute_generic_action(request, opts)
      end

    result
  end

  # ---------------------------------------------------------------------------
  # Stage 3: Process Result
  # ---------------------------------------------------------------------------

  @doc """
  Stage 3: Filter result fields using the extraction template.

  Applies field selection to the Ash result using the pre-computed template.
  Performance-optimized single-pass filtering.
  Handles metadata extraction for both read and mutation actions.
  """
  @spec process_result(term(), Request.t(), config()) :: {:ok, term()} | {:error, term()}
  def process_result(ash_result, %Request{} = request, config \\ %{}) do
    case ash_result do
      {:error, error} ->
        {:error, error}

      result when is_list(result) or is_map(result) or is_tuple(result) ->
        # For mutations with no field selection, use empty data
        is_mutation_with_no_fields =
          request.extraction_template == [] and
            request.action.type in [:create, :update, :destroy]

        if is_mutation_with_no_fields and Enum.empty?(request.show_metadata) do
          {:ok, %{}}
        else
          if unconstrained_map_action?(request.action) do
            {:ok, ResultProcessor.normalize_primitive(result)}
          else
            resource_for_mapping =
              get_field_mapping_module(request.action, request.resource, config)

            processor_config = %{
              field_names_callback: Map.get(config, :field_names_callback, :interop_field_names)
            }

            filtered =
              if is_mutation_with_no_fields do
                %{}
              else
                ResultProcessor.process(
                  result,
                  request.extraction_template,
                  resource_for_mapping,
                  processor_config
                )
              end

            filtered_with_metadata = add_metadata(filtered, result, request, config)

            {:ok, filtered_with_metadata}
          end
        end

      primitive_value ->
        {:ok, ResultProcessor.normalize_primitive(primitive_value)}
    end
  end

  # ---------------------------------------------------------------------------
  # Stage 4: Format Output
  # ---------------------------------------------------------------------------

  @doc """
  Stage 4: Format output for client consumption.

  Applies output field formatting and final response structure.
  """
  @spec format_output(term(), config()) :: term()
  def format_output(filtered_result, config \\ %{}) do
    formatter = Map.get(config, :output_field_formatter, :camel_case)
    format_field_names(filtered_result, formatter)
  end

  @doc """
  Stage 4: Format output for client consumption with type awareness.

  Applies type-aware output field formatting and final response structure.
  """
  @spec format_output_with_request(term(), Request.t(), config()) :: term()
  def format_output_with_request(filtered_result, %Request{} = request, config \\ %{}) do
    formatter = Map.get(config, :output_field_formatter, :camel_case)
    format_output_data(filtered_result, formatter, request, config)
  end

  # ---------------------------------------------------------------------------
  # Action Execution Helpers
  # ---------------------------------------------------------------------------

  defp execute_read_action(%Request{} = request, opts, config) do
    if Map.get(request.action, :get?, false) do
      query =
        request.resource
        |> Ash.Query.for_read(request.action.name, request.input, opts)
        |> apply_select_and_load(request)
        |> apply_get_by_filter(request.get_by)

      not_found_error? = Map.get(config, :not_found_error?, true)

      case Ash.read_one(query) do
        {:ok, nil} when not_found_error? ->
          {:error, Ash.Error.Query.NotFound.exception(resource: request.resource)}

        result ->
          result
      end
    else
      query =
        request.resource
        |> Ash.Query.for_read(request.action.name, request.input, opts)
        |> apply_select_and_load(request)
        |> apply_filter(request.filter)
        |> apply_sort(request.sort)
        |> apply_pagination(request.pagination)

      Ash.read(query)
    end
  end

  defp execute_create_action(%Request{} = request, opts) do
    request.resource
    |> Ash.Changeset.for_create(request.action.name, request.input, opts)
    |> Ash.Changeset.select(request.select)
    |> Ash.Changeset.load(request.load)
    |> Ash.create()
  end

  defp execute_update_action(%Request{} = request, opts) do
    read_action = Map.get(request.rpc_action, :read_action)
    identities = Map.get(request.rpc_action, :identities, [:_primary_key])

    base_query =
      request.resource
      |> Ash.Query.set_tenant(opts[:tenant])
      |> Ash.Query.set_context(opts[:context] || %{})

    with {:ok, query_with_identity} <-
           maybe_apply_identity_filter(base_query, request.identity, identities, request.resource) do
      query = Ash.Query.limit(query_with_identity, 1)

      bulk_opts = [
        return_errors?: true,
        notify?: true,
        strategy: [:atomic, :stream, :atomic_batches],
        allow_stream_with: :full_read,
        authorize_changeset_with: authorize_bulk_with(request.resource),
        return_records?: true,
        tenant: opts[:tenant],
        context: opts[:context] || %{},
        actor: opts[:actor],
        domain: request.domain,
        select: request.select,
        load: request.load
      ]

      bulk_opts =
        if read_action do
          Keyword.put(bulk_opts, :read_action, read_action)
        else
          bulk_opts
        end

      result =
        query
        |> Ash.bulk_update(request.action.name, request.input, bulk_opts)

      case result do
        %Ash.BulkResult{status: :success, records: [record]} ->
          {:ok, record}

        %Ash.BulkResult{status: :success, records: []} ->
          {:error, Ash.Error.Query.NotFound.exception(resource: request.resource)}

        %Ash.BulkResult{errors: errors} when errors != [] ->
          {:error, errors}

        other ->
          {:error, other}
      end
    end
  end

  defp execute_destroy_action(%Request{} = request, opts) do
    read_action = Map.get(request.rpc_action, :read_action)
    identities = Map.get(request.rpc_action, :identities, [:_primary_key])

    base_query =
      request.resource
      |> Ash.Query.set_tenant(opts[:tenant])
      |> Ash.Query.set_context(opts[:context] || %{})

    with {:ok, query_with_identity} <-
           maybe_apply_identity_filter(base_query, request.identity, identities, request.resource) do
      query =
        query_with_identity
        |> Ash.Query.limit(1)
        |> apply_select_and_load(request)

      bulk_opts = [
        return_errors?: true,
        notify?: true,
        strategy: [:atomic, :stream, :atomic_batches],
        allow_stream_with: :full_read,
        authorize_changeset_with: authorize_bulk_with(request.resource),
        return_records?: true,
        tenant: opts[:tenant],
        context: opts[:context] || %{},
        actor: opts[:actor],
        domain: request.domain
      ]

      bulk_opts =
        if read_action do
          Keyword.put(bulk_opts, :read_action, read_action)
        else
          bulk_opts
        end

      result =
        query
        |> Ash.bulk_destroy(request.action.name, request.input, bulk_opts)

      case result do
        %Ash.BulkResult{status: :success, records: [record]} ->
          {:ok, record}

        %Ash.BulkResult{status: :success, records: []} ->
          {:ok, %{}}

        %Ash.BulkResult{errors: errors} when errors != [] ->
          {:error, errors}

        other ->
          {:error, other}
      end
    end
  end

  defp execute_generic_action(%Request{} = request, opts) do
    action_result =
      request.resource
      |> Ash.ActionInput.for_action(request.action.name, request.input, opts)
      |> Ash.run_action()

    case action_result do
      {:ok, result} ->
        returns_resource? = action_returns_resource?(request.action)

        if returns_resource? and not Enum.empty?(request.load) do
          Ash.load(result, request.load, opts)
        else
          action_result
        end

      :ok ->
        {:ok, %{}}

      _ ->
        action_result
    end
  end

  # ---------------------------------------------------------------------------
  # Query Helpers
  # ---------------------------------------------------------------------------

  defp apply_filter(query, nil), do: query
  defp apply_filter(query, filter), do: Ash.Query.filter_input(query, filter)

  defp apply_get_by_filter(query, nil), do: query

  defp apply_get_by_filter(query, get_by) when is_map(get_by) do
    filter = Enum.map(get_by, fn {field, value} -> {field, value} end)
    Ash.Query.do_filter(query, filter)
  end

  defp apply_sort(query, nil), do: query
  defp apply_sort(query, sort), do: Ash.Query.sort_input(query, sort)

  defp apply_pagination(query, nil), do: Ash.Query.page(query, nil)
  defp apply_pagination(query, page), do: Ash.Query.page(query, page)

  defp apply_select_and_load(query, request) do
    query =
      if request.select && request.select != [] do
        Ash.Query.select(query, request.select)
      else
        query
      end

    if request.load && request.load != [] do
      Ash.Query.load(query, request.load)
    else
      query
    end
  end

  # ---------------------------------------------------------------------------
  # Identity Helpers
  # ---------------------------------------------------------------------------

  defp maybe_apply_identity_filter(query, _identity, [], _resource), do: {:ok, query}

  defp maybe_apply_identity_filter(query, identity, identities, resource)
       when is_map(identity) do
    case build_identity_filter(resource, identity, identities) do
      {:ok, filter} ->
        {:ok, Ash.Query.do_filter(query, filter)}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_apply_identity_filter(query, identity, identities, resource)
       when not is_nil(identity) do
    case build_identity_filter(resource, identity, identities) do
      {:ok, filter} ->
        {:ok, Ash.Query.do_filter(query, filter)}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_apply_identity_filter(_query, nil, identities, resource) when identities != [] do
    expected_keys = get_expected_identity_keys(resource, identities)

    {:error,
     {:missing_identity,
      %{
        expected_keys: expected_keys,
        identities: identities
      }}}
  end

  defp maybe_apply_identity_filter(query, _identity, _identities, _resource), do: {:ok, query}

  defp build_identity_filter(resource, identity, identities) when is_map(identity) do
    result =
      Enum.find_value(identities, fn
        :_primary_key ->
          primary_key_attrs = Ash.Resource.Info.primary_key(resource)

          if length(primary_key_attrs) > 1 &&
               Enum.all?(primary_key_attrs, &Map.has_key?(identity, &1)) do
            {:ok, primary_key_filter(resource, identity)}
          else
            nil
          end

        identity_name ->
          identity_info = Ash.Resource.Info.identity(resource, identity_name)

          if identity_info && Enum.all?(identity_info.keys, &Map.has_key?(identity, &1)) do
            {:ok, build_named_identity_filter(identity_info, identity)}
          else
            nil
          end
      end)

    case result do
      {:ok, filter} ->
        {:ok, filter}

      nil ->
        provided_keys = Map.keys(identity)
        expected_keys = get_expected_identity_keys(resource, identities)

        {:error,
         {:invalid_identity,
          %{
            provided_keys: provided_keys,
            expected_keys: expected_keys,
            identities: identities
          }}}
    end
  end

  defp build_identity_filter(resource, identity, identities) when not is_nil(identity) do
    if :_primary_key in identities do
      {:ok, primary_key_filter(resource, identity)}
    else
      {:error,
       {:invalid_identity,
        %{
          message: "Primary key identity not allowed for this action",
          identities: identities
        }}}
    end
  end

  defp build_identity_filter(_resource, _identity, _identities), do: {:ok, []}

  defp primary_key_filter(resource, primary_key_value) do
    primary_key_fields = Ash.Resource.Info.primary_key(resource)

    if is_map(primary_key_value) do
      Enum.map(primary_key_fields, fn field ->
        {field, Map.get(primary_key_value, field)}
      end)
    else
      [{List.first(primary_key_fields), primary_key_value}]
    end
  end

  defp build_named_identity_filter(identity, parsed_identity) when is_map(parsed_identity) do
    Enum.map(identity.keys, fn key ->
      {key, Map.get(parsed_identity, key) || Map.get(parsed_identity, Atom.to_string(key))}
    end)
  end

  defp get_expected_identity_keys(resource, identities) do
    Enum.flat_map(identities, fn
      :_primary_key ->
        Ash.Resource.Info.primary_key(resource)

      identity_name ->
        case Ash.Resource.Info.identity(resource, identity_name) do
          nil -> []
          identity -> identity.keys
        end
    end)
    |> Enum.uniq()
  end

  defp authorize_bulk_with(resource) do
    if Ash.DataLayer.data_layer_can?(resource, :expr_error) do
      :error
    else
      :filter
    end
  end

  # ---------------------------------------------------------------------------
  # Output Formatting Helpers
  # ---------------------------------------------------------------------------

  defp format_field_names(data, formatter) do
    case data do
      map when is_map(map) and not is_struct(map) ->
        Enum.into(map, %{}, fn {key, value} ->
          formatted_key =
            case key do
              atom when is_atom(atom) ->
                FieldFormatter.format_field_name(to_string(atom), formatter)

              string when is_binary(string) ->
                FieldFormatter.format_field_name(string, formatter)

              other ->
                other
            end

          {formatted_key, format_field_names(value, formatter)}
        end)

      list when is_list(list) ->
        Enum.map(list, &format_field_names(&1, formatter))

      other ->
        other
    end
  end

  defp format_output_data(%{success: true, data: result_data} = result, formatter, request, config) do
    {actual_data, metadata} =
      if is_map(result_data) and Map.has_key?(result_data, :data) and
           Map.has_key?(result_data, :metadata) do
        {result_data.data, result_data.metadata}
      else
        {result_data, Map.get(result, :metadata)}
      end

    formatted_data =
      format_action_output(actual_data, request.action, request.resource, formatter, config)

    base_response = %{
      FieldFormatter.format_field_name("success", formatter) => true,
      FieldFormatter.format_field_name("data", formatter) => formatted_data
    }

    case metadata do
      nil ->
        base_response

      meta when is_map(meta) ->
        formatted_metadata = format_field_names(meta, formatter)

        Map.put(
          base_response,
          FieldFormatter.format_field_name("metadata", formatter),
          formatted_metadata
        )
    end
  end

  defp format_output_data(%{success: false, errors: errors}, formatter, _request, _config) do
    formatted_errors = Enum.map(errors, &format_field_names(&1, formatter))

    %{
      FieldFormatter.format_field_name("success", formatter) => false,
      FieldFormatter.format_field_name("errors", formatter) => formatted_errors
    }
  end

  defp format_output_data(%{success: true}, formatter, _request, _config) do
    %{
      FieldFormatter.format_field_name("success", formatter) => true
    }
  end

  defp format_action_output(data, action, default_resource, formatter, config) do
    if action.type != :action do
      # For CRUD actions, use resource-based formatting
      format_resource_output(data, default_resource, formatter, config)
    else
      # For generic actions, use type-aware formatting
      format_generic_action_output(data, action, formatter, config)
    end
  end

  defp format_resource_output(data, resource, formatter, config) do
    value_formatter_config = %{
      input_field_formatter: Map.get(config, :input_field_formatter, :camel_case),
      output_field_formatter: formatter,
      field_names_callback: Map.get(config, :field_names_callback, :interop_field_names),
      get_original_field_name: Map.get(config, :get_original_field_name),
      format_field_for_client: Map.get(config, :format_field_for_client)
    }

    ValueFormatter.format(data, resource, [], :output, value_formatter_config)
  end

  defp format_generic_action_output(data, action, formatter, config) do
    return_type = action.returns
    constraints = action.constraints || []

    value_formatter_config = %{
      input_field_formatter: Map.get(config, :input_field_formatter, :camel_case),
      output_field_formatter: formatter,
      field_names_callback: Map.get(config, :field_names_callback, :interop_field_names),
      get_original_field_name: Map.get(config, :get_original_field_name),
      format_field_for_client: Map.get(config, :format_field_for_client)
    }

    ValueFormatter.format(data, return_type, constraints, :output, value_formatter_config)
  end

  # ---------------------------------------------------------------------------
  # Type Introspection Helpers
  # ---------------------------------------------------------------------------

  defp unconstrained_map_action?(action) do
    action.type == :action && action.returns == Ash.Type.Map &&
      (action.constraints == nil || action.constraints == [])
  end

  defp action_returns_resource?(action) do
    case action.returns do
      nil ->
        false

      type when is_atom(type) ->
        Ash.Resource.Info.resource?(type)

      {:array, type} when is_atom(type) ->
        Ash.Resource.Info.resource?(type)

      _ ->
        false
    end
  end

  defp get_field_mapping_module(action, default_resource, config) do
    if action.type != :action do
      default_resource
    else
      field_names_callback = Map.get(config, :field_names_callback, :interop_field_names)

      case get_action_return_type_info(action) do
        {:resource, resource_module} ->
          resource_module

        {:typed_struct, module} ->
          if function_exported?(module, field_names_callback, 0), do: module, else: nil

        _ ->
          default_resource
      end
    end
  end

  defp get_action_return_type_info(action) do
    return_type = action.returns
    constraints = action.constraints || []

    cond do
      is_nil(return_type) ->
        {:none, nil}

      is_atom(return_type) && Ash.Resource.Info.resource?(return_type) ->
        {:resource, return_type}

      match?({:array, type} when is_atom(type), return_type) ->
        {:array, inner_type} = return_type

        if Ash.Resource.Info.resource?(inner_type) do
          {:array_of_resource, inner_type}
        else
          {:array, inner_type}
        end

      return_type == Ash.Type.Struct && Keyword.has_key?(constraints, :instance_of) ->
        {:typed_struct, Keyword.get(constraints, :instance_of)}

      return_type in [Ash.Type.Map, Ash.Type.Struct] &&
          Introspection.has_field_constraints?(constraints) ->
        {:typed_map, constraints}

      true ->
        {:other, return_type}
    end
  end

  # ---------------------------------------------------------------------------
  # Metadata Helpers
  # ---------------------------------------------------------------------------

  defp add_metadata(filtered_result, original_result, %Request{} = request, _config) do
    if Enum.empty?(request.show_metadata) do
      filtered_result
    else
      case request.action.type do
        :read ->
          add_read_metadata(
            filtered_result,
            original_result,
            request.show_metadata
          )

        action_type when action_type in [:create, :update, :destroy] ->
          add_mutation_metadata(
            filtered_result,
            original_result,
            request.show_metadata
          )

        _ ->
          filtered_result
      end
    end
  end

  defp add_read_metadata(filtered_result, original_result, show_metadata)
       when is_list(filtered_result) do
    if is_list(original_result) do
      Enum.zip(filtered_result, original_result)
      |> Enum.map(fn {filtered_record, original_record} ->
        do_add_read_metadata(filtered_record, original_record, show_metadata)
      end)
    else
      filtered_result
    end
  end

  defp add_read_metadata(filtered_result, original_result, show_metadata)
       when is_map(filtered_result) do
    if Map.has_key?(filtered_result, :results) do
      updated_results =
        Enum.zip(filtered_result[:results] || [], original_result.results)
        |> Enum.map(fn {filtered_record, original_record} ->
          do_add_read_metadata(filtered_record, original_record, show_metadata)
        end)

      Map.put(filtered_result, :results, updated_results)
    else
      do_add_read_metadata(filtered_result, original_result, show_metadata)
    end
  end

  defp add_read_metadata(filtered_result, _original_result, _show_metadata) do
    filtered_result
  end

  defp do_add_read_metadata(filtered_record, original_record, show_metadata)
       when is_map(filtered_record) do
    metadata_map = Map.get(original_record, :__metadata__, %{})
    extracted_metadata = extract_metadata_fields(metadata_map, show_metadata)
    Map.merge(filtered_record, extracted_metadata)
  end

  defp do_add_read_metadata(filtered_record, _original_record, _show_metadata) do
    filtered_record
  end

  defp add_mutation_metadata(filtered_result, original_result, show_metadata) do
    metadata_map = Map.get(original_result, :__metadata__, %{})
    extracted_metadata = extract_metadata_fields(metadata_map, show_metadata)
    %{data: filtered_result, metadata: extracted_metadata}
  end

  defp extract_metadata_fields(metadata_map, show_metadata) do
    Enum.reduce(show_metadata, %{}, fn metadata_field, acc ->
      Map.put(acc, metadata_field, Map.get(metadata_map, metadata_field))
    end)
  end

  # ---------------------------------------------------------------------------
  # Sort String Formatting (Utility)
  # ---------------------------------------------------------------------------

  @doc """
  Formats a sort string by converting field names from client format to internal format.

  Handles Ash.Query.sort_input format:
  - "name" or "+name" (ascending)
  - "++name" (ascending with nils first)
  - "-name" (descending)
  - "--name" (descending with nils last)
  - "-name,++title" (multiple fields with different modifiers)

  Preserves sort modifiers while converting field names using the input formatter.

  ## Examples

      iex> format_sort_string("--startDate,++insertedAt", :camel_case)
      "--start_date,++inserted_at"

      iex> format_sort_string("-userName", :camel_case)
      "-user_name"

      iex> format_sort_string(nil, :camel_case)
      nil
  """
  def format_sort_string(nil, _formatter), do: nil

  def format_sort_string(sort_string, formatter) when is_binary(sort_string) do
    sort_string
    |> String.split(",")
    |> Enum.map_join(",", &format_single_sort_field(&1, formatter))
  end

  defp format_single_sort_field(field_with_modifier, formatter) do
    case field_with_modifier do
      "++" <> field_name ->
        formatted_field = FieldFormatter.parse_input_field(field_name, formatter)
        "++#{formatted_field}"

      "--" <> field_name ->
        formatted_field = FieldFormatter.parse_input_field(field_name, formatter)
        "--#{formatted_field}"

      "+" <> field_name ->
        formatted_field = FieldFormatter.parse_input_field(field_name, formatter)
        "+#{formatted_field}"

      "-" <> field_name ->
        formatted_field = FieldFormatter.parse_input_field(field_name, formatter)
        "-#{formatted_field}"

      field_name ->
        formatted_field = FieldFormatter.parse_input_field(field_name, formatter)
        "#{formatted_field}"
    end
  end
end
