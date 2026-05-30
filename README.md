# ExTurso

An Elixir library that wraps the [`turso`](https://crates.io/crates/turso) Rust
crate (v0.5) via [Rustler](https://github.com/rusterlium/rustler) NIFs, exposed
through a [`DBConnection`](https://hexdocs.pm/db_connection) pool.

This first cut focuses on **local file databases**, correct `ResourceArc`
lifetime management, and a working connection pool. Turso Cloud, embedded
replica sync, vector search, and migrations are intentionally out of scope.

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

## Architecture

| Layer | Module / file | Role |
| --- | --- | --- |
| Native | `native/ex_turso/src/lib.rs` | Rustler NIFs over `turso`, driven by a global Tokio runtime |
| NIF decls | `ExTurso.Native` | Loads the compiled NIF |
| Pooling | `ExTurso.Connection` | `DBConnection` behaviour implementation |
| Query | `ExTurso.Query` | Statement struct + `DBConnection.Query` protocol |
| Public API | `ExTurso` | `start_link/1`, `child_spec/1`, `query/3`, `execute/3` |
