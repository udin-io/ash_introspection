# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.ManifestError do
  @moduledoc """
  Raised when the request path is handed a manifest it cannot read from.

  Every one of these is a wiring mistake in the consumer, caught at the first
  request rather than answered from live `Ash.Resource.Info`. Before 0.6.0 each
  of the three read live instead, which was right and silent — and silence is
  what let stage 4 of the pipeline read live introspection for every release
  since the `:manifest` key landed. See `docs/decisions.md`.

  `reason` names which mistake:

  | `reason` | What happened |
  |---|---|
  | `:missing` | the config map passed to a request entry point carried no `:manifest` |
  | `:undecorated` | the manifest carries `resource`, but `AshIntrospection.Manifest.Decorator` never decorated it under `custom.<namespace>` |
  | `:unknown_resource` | the manifest does not carry `resource` at all, and `reader` has no live fallback on the request path |

  `resource`, `namespace` and `reader` are set where they apply and `nil`
  otherwise, so a consumer can match on the struct instead of on the message.
  """

  @typedoc "Which wiring mistake was found."
  @type reason :: :missing | :undecorated | :unknown_resource

  @type t :: %__MODULE__{
          __exception__: true,
          message: String.t(),
          reason: reason(),
          resource: module() | nil,
          namespace: atom() | nil,
          reader: String.t() | nil
        }

  defexception [:message, :reason, :resource, :namespace, :reader]

  @entry_points """
  `AshIntrospection.Rpc.Pipeline.execute_ash_action/2`, \
  `AshIntrospection.Rpc.Pipeline.process_result/3`, \
  `AshIntrospection.Rpc.Pipeline.format_output_with_request/3` and \
  `AshIntrospection.Rpc.FieldProcessing.FieldSelector.process/4`\
  """

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      reason: reason,
      resource: Keyword.get(opts, :resource),
      namespace: Keyword.get(opts, :namespace),
      reader: Keyword.get(opts, :reader),
      message: message(reason, opts)
    }
  end

  defp message(:missing, _opts) do
    """
    The request path requires a manifest from ash_introspection 0.6.0 on.

    The config map passed to #{@entry_points} must carry a `:manifest`. Build \
    one with `Ash.Info.Manifest.generate/1`, decorate it with \
    `AshIntrospection.Manifest.Decorator.decorate/3`, and put it on the config \
    together with the `:manifest_namespace` you decorated under.

    Until 0.5.3 a config with no `:manifest` read live `Ash.Resource.Info` on \
    every request instead. That path is gone from the request entry points; it \
    is still what the compile-time verifiers, codegen and the decorator use.
    """
  end

  defp message(:undecorated, opts) do
    resource = inspect(Keyword.get(opts, :resource))
    namespace = Keyword.get(opts, :namespace)

    """
    The manifest carries #{resource}, but `AshIntrospection.Manifest.Decorator` \
    did not decorate it under `custom.#{namespace}`.

    The decorator skips a module it cannot load at decoration time, so an \
    undecorated resource means the manifest module compiled before that module \
    did. Give the manifest module a compile-time dependency on the domains it \
    was built from, and force every referenced module to compile first.

    Check the namespace too: a manifest decorated under one key and read with \
    `manifest_namespace` set to another looks exactly like this.

    Until 0.5.3 an undecorated resource read live `Ash.Resource.Info` and the \
    answer was right, so nothing said the decoration had been missed.
    """
  end

  defp message(:unknown_resource, opts) do
    resource = inspect(Keyword.get(opts, :resource))
    reader = Keyword.get(opts, :reader)

    """
    The manifest does not carry #{resource}, and `#{reader}` has no live \
    fallback on the request path.

    This reader is only ever asked about the resource the request names, so a \
    miss means the manifest was built without an entrypoint for it. Add one to \
    the `:action_entrypoints` the manifest is generated from.

    Until 0.5.3 this read live `Ash.Resource.Info` instead.
    """
  end
end
