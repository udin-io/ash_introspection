<!--
SPDX-FileCopyrightText: 2025 ash_introspection contributors

SPDX-License-Identifier: MIT
-->

# AshIntrospection project source of truth

This is the hub for what this library is, where it is going, what could break
it, and which decisions still shape it. Issue #36 found the repo carried none
of that in writing, so every session rediscovered the same conditions from the
code. Read this page, then open the one that answers your question. Everything
here describes `main` as it is right now, not as anyone intends it to be.

## What this system is

`ash_introspection` is the shared core of Ash's language interop. It carries
what every language generator needs — type introspection, a four-stage RPC
pipeline, bidirectional field-name mapping, and error formatting — so each
generator does not reimplement them. It was extracted from `ash_typescript`,
which stayed a standalone upstream library and does **not** depend on this one.
Today `ash_kotlin_multiplatform` is the only consumer.

It is a library, not an application: no supervision tree, no endpoint, no
database. Tests run against `Ash.DataLayer.Ets`. The published surface is 21
modules — `AshIntrospection` plus 20 under `lib/ash_introspection/` — and
the `mix ash_introspection.upgrade` codemod task.

## The pages

| Page | Answers | Status |
|---|---|---|
| [architecture.md](architecture.md) | What the pieces are, who calls what, which modules the consumer actually uses | Current as of 0.3.0 |
| [roadmap.md](roadmap.md) | What shipped, what is open with ticket numbers, what is next, what was declined | Current as of 0.3.0; 19 issues open |
| [risks.md](risks.md) | What could go wrong, what we watch, what we would do | 4 live technical risks, 1 operational, 1 product |
| [decisions.md](decisions.md) | The choices that still shape the library, dated, with what each cost | 9 entries, latest 2026-09-09 |

## Keeping this current

These pages are part of the change, not a follow-up to it. A pull request that
changes behaviour, structure, a risk or a decision updates the affected pages
in the same pull request, and a merge is not finished until they describe
`main` as it now is. Concretely:

- A new module, a new dependency edge, or a change to who calls what redraws
  [architecture.md](architecture.md).
- A closed issue moves on [roadmap.md](roadmap.md); a declined one moves to
  "Decided against" with the reason.
- A risk the change creates or retires is added to or struck from
  [risks.md](risks.md).
- A choice a future reader would otherwise question gets a dated entry in
  [decisions.md](decisions.md), including what it cost.

A source of truth that lags is worse than none, because readers trust it.
Repo-specific working rules — traps, conventions, commands that must be run a
certain way — live in [`CLAUDE.md`](../CLAUDE.md) at the repo root, not here.
