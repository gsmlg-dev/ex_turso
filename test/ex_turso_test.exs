defmodule ExTursoTest do
  use ExUnit.Case, async: true

  alias ExTurso.Result

  setup do
    # Each test gets its own in-memory database with a single connection so the
    # data stays on one handle.
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({ExTurso, database: ":memory:", name: name, pool_size: 1})
    {:ok, _} = ExTurso.execute(name, "CREATE TABLE users (id INTEGER, name TEXT, score REAL)")
    %{db: name}
  end

  test "execute reports affected rows", %{db: db} do
    assert {:ok, %Result{num_rows: 1, rows: nil}} =
             ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 9.5])
  end

  test "query returns rows as maps keyed by column name", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 9.5])

    assert {:ok, %Result{num_rows: 1, rows: [%{"id" => 1, "name" => "Alice", "score" => 9.5}]}} =
             ExTurso.query(db, "SELECT id, name, score FROM users WHERE id = ?", [1])
  end

  test "parameters bind across types including nil", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [2, "Bob", nil])

    assert {:ok, %Result{rows: [%{"name" => "Bob", "score" => nil}]}} =
             ExTurso.query(db, "SELECT name, score FROM users WHERE id = ?", [2])
  end

  test "empty result set", %{db: db} do
    assert {:ok, %Result{num_rows: 0, rows: []}} =
             ExTurso.query(db, "SELECT * FROM users", [])
  end

  test "errors surface as {:error, exception}", %{db: db} do
    assert {:error, %ExTurso.Error{message: message}} =
             ExTurso.query(db, "SELECT * FROM nonexistent", [])

    assert is_binary(message)
  end

  test "transaction commits", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 1.0])

    assert {:ok, :done} =
             DBConnection.transaction(db, fn conn ->
               {:ok, _} =
                 ExTurso.execute(conn, "UPDATE users SET score = ? WHERE id = ?", [10.0, 1])

               :done
             end)

    assert {:ok, %Result{rows: [%{"score" => 10.0}]}} =
             ExTurso.query(db, "SELECT score FROM users WHERE id = ?", [1])
  end

  test "transaction rolls back on error", %{db: db} do
    {:ok, _} = ExTurso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 1.0])

    assert {:error, :boom} =
             DBConnection.transaction(db, fn conn ->
               {:ok, _} =
                 ExTurso.execute(conn, "UPDATE users SET score = ? WHERE id = ?", [99.0, 1])

               DBConnection.rollback(conn, :boom)
             end)

    assert {:ok, %Result{rows: [%{"score" => 1.0}]}} =
             ExTurso.query(db, "SELECT score FROM users WHERE id = ?", [1])
  end
end
