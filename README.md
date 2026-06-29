# ExTurso

[![CI](https://github.com/gsmlg-dev/ex_turso/actions/workflows/ci.yml/badge.svg)](https://github.com/gsmlg-dev/ex_turso/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ex_turso.svg)](https://hex.pm/packages/ex_turso)

An Elixir library that wraps the [`turso`](https://crates.io/crates/turso) Rust
crate (v0.5) via [Rustler](https://github.com/rusterlium/rustler) NIFs, exposed
through a [`DBConnection`](https://hexdocs.pm/db_connection) pool.

It supports **local file databases** (and `":memory:"`), **Turso Cloud sync**
via embedded replicas, and turso's built-in **vector search** and **full-text
search** SQL features, with correct `ResourceArc` lifetime management and a
working connection pool. Migrations and an Ecto adapter are out of scope.

## Native binaries

Release builds use precompiled NIFs when available, so most users do not need a
Rust toolchain. Precompiled binaries are published for:

| OS | Architectures |
| --- | --- |
| Linux | `aarch64`, `x86_64` |
| macOS | `aarch64`, `x86_64` |
| FreeBSD | `x86_64` |
| Windows | `x86_64` |

Set `EX_TURSO_BUILD=1` to force a source build. A working Rust toolchain
(`cargo`) matching your BEAM's architecture is required for source builds.

## Installation

```elixir
def deps do
  [
    {:ex_turso, "~> 0.1.0"}
  ]
end
```

## Usage

Start a pool under your supervision tree:

```elixir
children = [
  {ExTurso, database: "my_app.db", name: MyApp.DB}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Then query and execute against the registered name:

```elixir
{:ok, _} = ExTurso.execute(MyApp.DB, "CREATE TABLE users (id INTEGER, name TEXT)")
{:ok, _} = ExTurso.execute(MyApp.DB, "INSERT INTO users VALUES (?, ?)", [1, "Alice"])

{:ok, %ExTurso.Result{rows: [%{"name" => "Alice"}]}} =
  ExTurso.query(MyApp.DB, "SELECT name FROM users WHERE id = ?", [1])
```

Transactions go through `DBConnection`:

```elixir
DBConnection.transaction(MyApp.DB, fn conn ->
  {:ok, _} = ExTurso.execute(conn, "UPDATE users SET name = ? WHERE id = ?", ["Bob", 1])
end)
```

Use `database: ":memory:"` for an in-memory database (one per pool connection).

Always pass values as bound parameters (`?`) rather than interpolating them
into the SQL string — statements are logged when a query errors.

## Full-text search

ExTurso enables Turso's embedded full-text search index support for local
databases. Use Turso's FTS index syntax:

```elixir
{:ok, _} = ExTurso.execute(MyApp.DB, "CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)")
{:ok, _} = ExTurso.execute(MyApp.DB, "CREATE INDEX docs_fts ON docs USING fts (content)")

{:ok, %ExTurso.Result{rows: rows}} =
  ExTurso.query(MyApp.DB, "SELECT id FROM docs WHERE (content) MATCH ?", ["search term"])
```

SQLite's FTS5 virtual table syntax, such as
`CREATE VIRTUAL TABLE docs_fts USING fts5(content)`, is not exposed by the
embedded `turso` crate v0.5 API. Use `CREATE INDEX ... USING fts` with `MATCH`
queries instead.

## Turso Cloud sync

Pass `:remote_url` and `:auth_token` to open the local file as an embedded
replica of a Turso Cloud database:

```elixir
children = [
  {ExTurso,
   database: "replica.db",
   remote_url: "libsql://my-db.turso.io",
   auth_token: fn -> System.fetch_env!("TURSO_AUTH_TOKEN") end,
   name: MyApp.DB}
]
```

`auth_token` accepts a string or a zero-arity function; prefer the function so
the token does not appear in supervisor child specs and crash reports.

Trigger a bidirectional sync (pull then push) with:

```elixir
:ok = ExTurso.sync(MyApp.DB)
```

Sync is rejected inside a transaction and on databases not configured with
`:remote_url`/`:auth_token`.

## Errors

Failures return `{:error, %ExTurso.Error{message: message, code: code}}`. The
`code` classifies the failure: `:busy` (locked, retryable), `:constraint`,
`:invalid_param` (unsupported bound parameter type), `:misuse`, `:error`, or
`:io`/`:corrupt` — the last two mark the connection as broken, so the pool
drops it and opens a fresh one.

## Architecture

| Layer | Module / file | Role |
| --- | --- | --- |
| Native | `native/ex_turso/src/lib.rs` | Rustler NIFs over `turso`, driven by a global Tokio runtime |
| NIF decls | `ExTurso.Native` | Loads the compiled NIF |
| Pooling | `ExTurso.Connection` | `DBConnection` behaviour implementation |
| Query | `ExTurso.Query` | Statement struct + `DBConnection.Query` protocol |
| Public API | `ExTurso` | `start_link/1`, `child_spec/1`, `query/3`, `execute/3` |
