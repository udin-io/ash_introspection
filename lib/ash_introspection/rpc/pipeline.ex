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

  ## Action metadata

  `Request.show_metadata` names the metadata fields stage 3 extracts, and this
  pipeline extracts exactly what it is given. **Deciding which metadata fields
  a client may ask for is the caller's job, not this pipeline's.** There is no
  parse stage here — `parse_request/3` lives in the language-specific wrapper
  — so nothing in this library filters a client-supplied field list against
  the action's declaration. A wrapper that passes client input into
  `show_metadata` unfiltered lets a client read any metadata field the action
  declares. `ash_kotlin_multiplatform` does filter, in
  `AshKotlinMultiplatform.Rpc.Runner`: `dsl_metadata_fields/2` reads the
  allowlist off the RPC DSL and `narrow_metadata_fields/2` intersects the
  client's request with it, so a client can only narrow, never widen. Upstream
  `ash_typescript` puts the same check in its own parse stage.

  Each extracted value is formatted once, by the type its action declared for
  it, and the response envelope then formats only the top-level metadata name.
  A metadata field declared as an unconstrained `:map` is an explicit opt-out
  of typing: its keys are the caller's and reach the client verbatim.

  That guarantee holds on `format_output_with_request/3`, which has the request
  and therefore the types. `format_output/2` has neither, so it falls back to
  formatting every key it can reach — including the keys inside an
  unconstrained map. A wrapper that wants type-correct output has to call
  `format_output_with_request/3`.
  """

  alias AshIntrospection.{ErrorFormatter, FieldFormatter}
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
          execute_update_action(request, opts, config)

        :destroy ->
          execute_destroy_action(request, opts, config)

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

  The error clause covers failures raised before a `%Request{}` exists — action
  discovery, identity resolution, parameter validation. It formats them exactly
  as `format_output_with_request/3` does, so both entry points hand the client
  the same response shape and the same client-resolvable placeholders.
  """
  @spec format_output(term(), config()) :: term()
  def format_output(filtered_result, config \\ %{})

  def format_output(%{success: false, errors: _} = filtered_result, config) do
    formatter = Map.get(config, :output_field_formatter, :camel_case)
    format_output_data(filtered_result, formatter, nil, config)
  end

  def format_output(filtered_result, config) do
    formatter = Map.get(config, :output_field_formatter, :camel_case)
    FieldFormatter.format_output_field_names(filtered_result, formatter)
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

  # `identity` is an update/destroy lookup key: `execute_update_action/3` and
  # `execute_destroy_action/3` are its only consumers, and a read selects a
  # record with `get_by`. A read used to carry `identity` as far as the query
  # and then drop it, so the caller asked for one record and got the whole
  # table back, or a `MultipleResults` from `Ash.read_one/1` naming nothing it
  # could act on. Rejecting is what upstream `ash_typescript` already means:
  # its `identities` option is empty for every action type but `:update` and
  # `:destroy`, so no generated client can send it on a read. See the
  # 2026-09-09 entry in `docs/decisions.md`.
  defp execute_read_action(%Request{identity: identity} = request, _opts, _config)
       when not is_nil(identity) do
    {:error, {:identity_not_supported, %{action: request.action.name}}}
  end

  defp execute_read_action(%Request{} = request, opts, config) do
    if Map.get(request.action, :get?, false) do
      with {:ok, query} <-
             request.resource
             |> Ash.Query.for_read(request.action.name, request.input, opts)
             |> apply_select_and_load(request)
             |> apply_get_by_filter(request.get_by, config) do
        not_found_error? = Map.get(config, :not_found_error?, true)

        case Ash.read_one(query) do
          {:ok, nil} when not_found_error? ->
            {:error, Ash.Error.Query.NotFound.exception(resource: request.resource)}

          result ->
            result
        end
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

  defp execute_update_action(%Request{} = request, opts, config) do
    read_action = Map.get(request.rpc_action, :read_action)
    identities = Map.get(request.rpc_action, :identities, [:_primary_key])

    base_query =
      request.resource
      |> Ash.Query.set_tenant(opts[:tenant])
      |> Ash.Query.set_context(opts[:context] || %{})

    with {:ok, query_with_identity} <-
           maybe_apply_identity_filter(
             base_query,
             request.identity,
             identities,
             request.resource,
             config
           ) do
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

  defp execute_destroy_action(%Request{} = request, opts, config) do
    read_action = Map.get(request.rpc_action, :read_action)
    identities = Map.get(request.rpc_action, :identities, [:_primary_key])

    base_query =
      request.resource
      |> Ash.Query.set_tenant(opts[:tenant])
      |> Ash.Query.set_context(opts[:context] || %{})

    with {:ok, query_with_identity} <-
           maybe_apply_identity_filter(
             base_query,
             request.identity,
             identities,
             request.resource,
             config
           ) do
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

  defp apply_get_by_filter(query, nil, _config), do: {:ok, query}

  defp apply_get_by_filter(query, get_by, config) when is_map(get_by) do
    with :ok <- validate_scalar_get_by(get_by, config) do
      filter = Enum.map(get_by, fn {field, value} -> {field, value} end)
      {:ok, Ash.Query.do_filter(query, filter)}
    end
  end

  # `get_by` values come from the client and are applied through the *trusted*
  # filter API (Ash.Query.do_filter/2), which reads a map or list operand as an
  # operator expression — `%{"less_than" => "b"}` becomes `field < "b"` — so an
  # exact-record lookup silently widens into an arbitrary predicate. `get_by`
  # lookups are equality-only, so reject any non-scalar value before it reaches
  # the filter.
  defp validate_scalar_get_by(get_by, config) do
    case non_scalar_filter_keys(get_by) do
      [] ->
        :ok

      keys ->
        {:error,
         {:invalid_get_by,
          %{
            message:
              "getBy values must be scalar equality operands. Non-scalar value provided for: " <>
                format_filter_keys(keys, config)
          }}}
    end
  end

  # JSON input yields only string, number, boolean, nil, list and map, so
  # "neither map nor list" rejects every operator expression while preserving
  # every legitimate operand — `false` and `nil` included.
  defp non_scalar_filter_keys(values) do
    for {key, value} <- values, is_map(value) or is_list(value), do: key
  end

  defp format_filter_keys(keys, config) do
    formatter = Map.get(config, :output_field_formatter, :camel_case)
    Enum.map_join(keys, ", ", &FieldFormatter.format_field_name(&1, formatter))
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

  defp maybe_apply_identity_filter(query, _identity, [], _resource, _config), do: {:ok, query}

  defp maybe_apply_identity_filter(query, identity, identities, resource, config)
       when is_map(identity) do
    with {:ok, filter} <- build_identity_filter(resource, identity, identities),
         :ok <- validate_non_null_identity_filter(filter, config),
         :ok <- validate_scalar_identity_filter(filter, config) do
      {:ok, Ash.Query.do_filter(query, filter)}
    end
  end

  defp maybe_apply_identity_filter(query, identity, identities, resource, config)
       when not is_nil(identity) do
    with {:ok, filter} <- build_identity_filter(resource, identity, identities),
         :ok <- validate_non_null_identity_filter(filter, config),
         :ok <- validate_scalar_identity_filter(filter, config) do
      {:ok, Ash.Query.do_filter(query, filter)}
    end
  end

  defp maybe_apply_identity_filter(_query, nil, identities, resource, _config)
       when identities != [] do
    expected_keys = get_expected_identity_keys(resource, identities)

    {:error,
     {:missing_identity,
      %{
        expected_keys: expected_keys,
        identities: identities
      }}}
  end

  defp maybe_apply_identity_filter(query, _identity, _identities, _resource, _config),
    do: {:ok, query}

  # A `nil` identity value compiles to `key == nil`, which Ash evaluates as
  # unknown rather than as a null check, so the lookup matched nothing and
  # surfaced as `NotFound` — an answer that reads as "no such record" when the
  # fault is an identity that cannot name one. Building `is_nil(key)` instead
  # would be worse: Ash identities default to `nils_distinct?: true`
  # (`deps/ash/lib/ash/resource/identity.ex:48`), so a null key does not
  # identify a single record, and `execute_update_action/3` and
  # `execute_destroy_action/3` take `Ash.Query.limit(query, 1)` — the exact
  # widening #8 closed for map and list operands. Reject the null instead.
  defp validate_non_null_identity_filter(filter, config) do
    case for {key, nil} <- filter, do: key do
      [] ->
        :ok

      keys ->
        {:error,
         {:invalid_identity,
          %{
            message:
              "Identity values may not be null. Null value provided for: " <>
                format_filter_keys(keys, config)
          }}}
    end
  end

  # Identity values come from the client and are applied through the *trusted*
  # filter API (Ash.Query.do_filter/2), which reads a map or list operand as an
  # operator expression — `%{"greater_than" => ""}` becomes `field > ""` — so
  # an exact-record lookup silently widens into an arbitrary predicate. That
  # predicate then drives `execute_update_action/3` and
  # `execute_destroy_action/3`, so it mutates or deletes a record the caller
  # never named. Identity lookups are equality-only, so reject any non-scalar
  # value before it reaches the filter.
  defp validate_scalar_identity_filter(filter, config) do
    case non_scalar_filter_keys(filter) do
      [] ->
        :ok

      keys ->
        {:error,
         {:invalid_identity,
          %{
            message:
              "Identity values must be scalar equality operands. Non-scalar value provided for: " <>
                format_filter_keys(keys, config)
          }}}
    end
  end

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

  # `Map.fetch!/2` rather than `Map.get/2 || Map.get/2`: a boolean identity key
  # valued `false` is falsy, so the `||` discarded it and the filter became
  # `key == nil`. The update or destroy then ran against a record the caller
  # never named, or against none at all.
  #
  # `fetch!` cannot raise here. `build_identity_filter/3` picks a named identity
  # only when `Enum.all?(identity_info.keys, &Map.has_key?(parsed_identity, &1))`
  # holds, so every atom key is present by the time this runs. #15 carried a
  # string-key fallback for parity with upstream `ash_typescript`; #44 removed
  # it because the same guard makes it unreachable there too, and dead code that
  # looks like a safety net invites the next reader to trust it.
  defp build_named_identity_filter(identity, parsed_identity) when is_map(parsed_identity) do
    Enum.map(identity.keys, fn key -> {key, Map.fetch!(parsed_identity, key)} end)
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

  defp format_output_data(
         %{success: true, data: result_data} = result,
         formatter,
         request,
         config
       ) do
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
        # Only the top-level metadata names are formatted here. The values
        # arrived from `extract_metadata_fields/4` already formatted by their
        # declared type, and formatting them again would undo that: a typed
        # value pinned to the client name `_rev` becomes `rev`, and the keys of
        # an unconstrained `:map` — an explicit opt-out of typing — get
        # renamed out from under the caller who wrote them.
        formatted_metadata =
          Map.new(meta, fn {key, value} ->
            {FieldFormatter.format_field_name(key, formatter), value}
          end)

        Map.put(
          base_response,
          FieldFormatter.format_field_name("metadata", formatter),
          formatted_metadata
        )
    end
  end

  defp format_output_data(%{success: false, errors: errors}, formatter, _request, _config) do
    formatted_errors = Enum.map(errors, &ErrorFormatter.format(&1, formatter))

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

  # A read hands stage 4 one of three shapes and only one of them used to
  # format. `ValueFormatter.format/5` unwraps a collection when the *type* says
  # `{:array, _}`, and this is the only caller that knows the data is a
  # collection of `resource`, because a resource module carries no cardinality.
  # #57: passing the bare module for a list left every record with internal
  # atom keys, and the paginated page — a map with `:results` — formatted its
  # own envelope and nothing inside it, since `:results` is not a field on the
  # resource so `ResourceFields.get_field_type_info/2` answers `{nil, []}`.
  # Both measured on `main` at `51a9c27`.
  #
  # The page clause formats `:results` first and then runs the page through the
  # resource path for its envelope names. That is not a double pass: the
  # already-formatted list sits under a key the resource does not define, and
  # `format/5` returns any value whose type is `nil` untouched.
  defp format_resource_output(data, resource, formatter, config) when is_list(data) do
    format_value(data, {:array, resource}, formatter, config)
  end

  defp format_resource_output(%{results: results} = page, resource, formatter, config)
       when is_list(results) do
    page
    |> Map.put(:results, format_value(results, {:array, resource}, formatter, config))
    |> format_value(resource, formatter, config)
  end

  defp format_resource_output(data, resource, formatter, config) do
    format_value(data, resource, formatter, config)
  end

  defp format_value(data, type, formatter, config) do
    ValueFormatter.format(data, type, [], :output, value_formatter_config(formatter, config))
  end

  defp format_generic_action_output(data, action, formatter, config) do
    return_type = action.returns
    constraints = action.constraints || []

    ValueFormatter.format(
      data,
      return_type,
      constraints,
      :output,
      value_formatter_config(formatter, config)
    )
  end

  defp value_formatter_config(formatter, config) do
    %{
      input_field_formatter: Map.get(config, :input_field_formatter, :camel_case),
      output_field_formatter: formatter,
      field_names_callback: Map.get(config, :field_names_callback, :interop_field_names),
      get_original_field_name: Map.get(config, :get_original_field_name),
      format_field_for_client: Map.get(config, :format_field_for_client)
    }
  end

  # ---------------------------------------------------------------------------
  # Type Introspection Helpers
  # ---------------------------------------------------------------------------

  # "Unconstrained" means no `:fields` to select against — never "no
  # constraints at all". Ash normalises a generic action's constraints through
  # `Ash.Type.init/2`, which fills in every default the return type declares, so
  # an action returning a bare `:map` arrives here carrying
  # `[preserve_nil_values?: false]` from `Ash.Type.Map`'s constraint schema
  # (`deps/ash/lib/ash/type/map.ex:7`). #62: this test used to compare the
  # keyword list against `[]`, which that default can never equal, so the skip
  # never fired and every untyped-map response went through the typed path and
  # came back as `nil` per requested field. Ask about `:fields` — the thing the
  # typed path actually needs — and a future ash release adding another default
  # cannot kill the check again.
  #
  # #64 is the same silent data loss one type shape over. `{:array, :map}`
  # normalises to `{:array, Ash.Type.Map}` and puts the element's constraints
  # under `:items`, so the tuple has to be unwrapped and the inner keyword list
  # asked the same question. Read `:items` with a `[]` default for the reason
  # `has_field_constraints?/1` exists: the constraint key is the question, never
  # the shape of the whole list.
  defp unconstrained_map_action?(action) do
    action.type == :action && untyped_map_return?(action.returns, action.constraints || [])
  end

  defp untyped_map_return?(Ash.Type.Map, constraints) do
    not Introspection.has_field_constraints?(constraints)
  end

  defp untyped_map_return?({:array, Ash.Type.Map}, constraints) do
    not Introspection.has_field_constraints?(Keyword.get(constraints, :items, []))
  end

  defp untyped_map_return?(_returns, _constraints), do: false

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
          # `Code.ensure_loaded?/1` first: Elixir loads modules lazily, so
          # `function_exported?/3` answers `false` for a consumer's struct
          # module nothing has touched in this process, and the mapping module
          # silently becomes `nil`. #49 swept the library for this; #52 guarded
          # nine sites and left this one, because #44 held this file.
          if Code.ensure_loaded?(module) and function_exported?(module, field_names_callback, 0),
            do: module,
            else: nil

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

  defp add_metadata(filtered_result, original_result, %Request{} = request, config) do
    if Enum.empty?(request.show_metadata) do
      filtered_result
    else
      case request.action.type do
        :read ->
          add_read_metadata(
            filtered_result,
            original_result,
            request.show_metadata,
            request.action,
            config
          )

        action_type when action_type in [:create, :update, :destroy] ->
          add_mutation_metadata(
            filtered_result,
            original_result,
            request.show_metadata,
            request.action,
            config
          )

        _ ->
          filtered_result
      end
    end
  end

  defp add_read_metadata(filtered_result, original_result, show_metadata, action, config)
       when is_list(filtered_result) do
    if is_list(original_result) do
      Enum.zip(filtered_result, original_result)
      |> Enum.map(fn {filtered_record, original_record} ->
        do_add_read_metadata(filtered_record, original_record, show_metadata, action, config)
      end)
    else
      filtered_result
    end
  end

  defp add_read_metadata(filtered_result, original_result, show_metadata, action, config)
       when is_map(filtered_result) do
    if Map.has_key?(filtered_result, :results) do
      updated_results =
        Enum.zip(filtered_result[:results] || [], original_result.results)
        |> Enum.map(fn {filtered_record, original_record} ->
          do_add_read_metadata(filtered_record, original_record, show_metadata, action, config)
        end)

      Map.put(filtered_result, :results, updated_results)
    else
      do_add_read_metadata(filtered_result, original_result, show_metadata, action, config)
    end
  end

  defp add_read_metadata(filtered_result, _original_result, _show_metadata, _action, _config) do
    filtered_result
  end

  defp do_add_read_metadata(filtered_record, original_record, show_metadata, action, config)
       when is_map(filtered_record) do
    metadata_map = Map.get(original_record, :__metadata__, %{})
    extracted_metadata = extract_metadata_fields(metadata_map, show_metadata, action, config)
    Map.merge(filtered_record, extracted_metadata)
  end

  defp do_add_read_metadata(filtered_record, _original_record, _show_metadata, _action, _config) do
    filtered_record
  end

  defp add_mutation_metadata(filtered_result, original_result, show_metadata, action, config) do
    metadata_map = Map.get(original_result, :__metadata__, %{})
    extracted_metadata = extract_metadata_fields(metadata_map, show_metadata, action, config)
    %{data: filtered_result, metadata: extracted_metadata}
  end

  # Each metadata value is formatted by the type its action declared for it, the
  # same type-driven dispatch attributes and calculations go through. That is
  # the only place the value can be formatted correctly, because it is the only
  # place the type is known: a metadata name is not an attribute, so stage 4
  # looks it up on the resource, finds nothing and hands the value back
  # untouched. Formatting here means stage 4 must not format these values a
  # second time — see `format_output_data/4`.
  #
  # Keys stay internal atoms. Stage 4 formats the top-level metadata name, once.
  defp extract_metadata_fields(metadata_map, show_metadata, action, config) do
    metadata_defs = Map.get(action, :metadata) || []
    formatter = Map.get(config, :output_field_formatter, :camel_case)
    value_config = value_formatter_config(formatter, config)

    Enum.reduce(show_metadata, %{}, fn metadata_field, acc ->
      {type, constraints} = metadata_field_type(metadata_defs, metadata_field)
      value = Map.get(metadata_map, metadata_field)

      Map.put(
        acc,
        metadata_field,
        ValueFormatter.format(value, type, constraints, :output, value_config)
      )
    end)
  end

  # A metadata field the action does not declare formats as `nil`, which
  # `ValueFormatter.format/5` passes through unchanged. That is the same answer
  # an unconstrained `:map` gets, and it is the right one: with no declared type
  # there is nothing to format the value by.
  defp metadata_field_type(metadata_defs, field_name) do
    case Enum.find(metadata_defs, &(Map.get(&1, :name) == field_name)) do
      nil -> {nil, []}
      definition -> {Map.get(definition, :type), Map.get(definition, :constraints) || []}
    end
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
