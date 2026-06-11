# ExTurso

An Elixir library that wraps the [`turso`](https://crates.io/crates/turso) Rust
crate (v0.5) via [Rustler](https://github.com/rusterlium/rustler) NIFs, exposed
through a [`DBConnection`](https://hexdocs.pm/db_connection) pool.

It supports **local file databases** (and `":memory:"`), **Turso Cloud sync**
via embedded replicas, and turso's built-in **vector search** SQL functions,
with correct `ResourceArc` lifetime management and a working connection pool.
Migrations and an Ecto adapter are out of scope.

## Requirements

A working Rust toolchain (`cargo`) matching your BEAM's architecture is required
to build the NIF.

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
