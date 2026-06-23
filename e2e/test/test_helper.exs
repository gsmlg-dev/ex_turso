ex_unit_opts =
  if System.get_env("EX_TURSO_INCLUDE_CLOUD") == "true" do
    []
  else
    [exclude: [cloud: true]]
  end

ExUnit.start(ex_unit_opts)

defmodule ExTursoE2E.Support do
  import ExUnit.Assertions

  alias ExTurso.Result

  def unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  def start_pool!(opts) do
    name = Keyword.get_lazy(opts, :name, fn -> unique_name(:db) end)
    opts = Keyword.put(opts, :name, name)

    spec = %{
      id: name,
      start: {ExTurso, :start_link, [opts]}
    }

    pid = ExUnit.Callbacks.start_supervised!(spec)
    {name, pid}
  end

  def stop_pool!(name) do
    ExUnit.Callbacks.stop_supervised!(name)
  end

  def execute!(conn, sql, params \\ []) do
    assert {:ok, %Result{}} = result = ExTurso.execute(conn, sql, params)
    result
  end

  def query!(conn, sql, params \\ []) do
    assert {:ok, %Result{}} = result = ExTurso.query(conn, sql, params)
    result
  end

  def query_one!(conn, sql, params \\ []) do
    assert {:ok, %Result{rows: [row]}} = ExTurso.query(conn, sql, params)
    row
  end

  def assert_float_close(actual, expected, tolerance \\ 1.0e-6) do
    assert is_number(actual)
    assert abs(actual - expected) <= tolerance
  end
end
