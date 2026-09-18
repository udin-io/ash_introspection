# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

defmodule AshIntrospection.Rpc.FieldExtractorTest do
  @moduledoc """
  Runs the examples in `AshIntrospection.Rpc.FieldExtractor`'s docs. They
  were not run by anything before #66 added `tuple_template/1`, so the
  tuple-placement contract the module states had no test of its own.
  """
  use ExUnit.Case, async: true

  doctest AshIntrospection.Rpc.FieldExtractor, import: true
end
