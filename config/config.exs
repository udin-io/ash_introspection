# SPDX-FileCopyrightText: 2025 ash_introspection contributors
#
# SPDX-License-Identifier: MIT

import Config

# Ash 3.33.0 fixed CVE-2026-82752 by refusing to compile a resource until the
# host application states how string length is counted. A single grapheme can
# carry unbounded combining marks, so grapheme counting let any string pass
# `max_length`. This library ships no config of its own — the setting below
# applies only to the test resources compiled here, and `mix.exs` keeps `config`
# out of the published package so consumers stay free to choose.
#
# `:codepoints` matches how SQL data layers count, so validation agrees with
# storage. See
# https://hexdocs.pm/ash/backwards-compatibility-config.html#default_string_length_count
config :ash, default_string_length_count: :codepoints
