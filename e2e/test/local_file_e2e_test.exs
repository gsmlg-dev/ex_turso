defmodule ExTursoE2E.LocalFileTest do
  use ExUnit.Case, async: true

  alias ExTurso.Result
  alias ExTursoE2E.Support

  @moduletag :tmp_dir

  test "file database persists rows across pool restarts", %{tmp_dir: tmp_dir} do
    db_path = Path.join(tmp_dir, "persistent.db")
    {db, _pid} = Support.start_pool!(database: db_path, pool_size: 1)

    Support.execute!(db, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    Support.execute!(db, "INSERT INTO people VALUES (?, ?)", [1, "Ada"])

    Support.stop_pool!(db)

    {reopened, _pid} = Support.start_pool!(database: db_path, pool_size: 1)

    assert {:ok, %Result{rows: [%{"name" => "Ada"}]}} =
             ExTurso.query(reopened, "SELECT name FROM people WHERE id = ?", [1])
  end

  test "separate in-memory pools do not share state" do
    {left, _pid} = Support.start_pool!(database: ":memory:", pool_size: 1)
    {right, _pid} = Support.start_pool!(database: ":memory:", pool_size: 1)

    Support.execute!(left, "CREATE TABLE local_only (id INTEGER PRIMARY KEY)")

    assert {:ok, %Result{rows: [%{"name" => "local_only"}]}} =
             ExTurso.query(left, "SELECT name FROM sqlite_schema WHERE type = 'table'")

    assert {:ok, %Result{rows: []}} =
             ExTurso.query(right, "SELECT name FROM sqlite_schema WHERE type = 'table'")
  end
end
