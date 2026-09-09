# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

import Config

# test/support/*.ex defines several throwaway Ash domains used only to drive
# the RPC pipeline in tests. They are intentionally not registered under
# `config :ash_introspection, ash_domains: [...]` because they aren't part of
# the library's public domain surface. Ash's compile-time check for that
# omission would otherwise fail `mix compile --warnings-as-errors` in CI.
# See https://github.com/udin-io/ash_introspection/issues/39.
config :ash, :validate_domain_config_inclusion?, false
