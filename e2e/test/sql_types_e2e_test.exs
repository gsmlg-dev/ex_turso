defmodule ExTursoE2E.SqlTypesTest do
  use ExUnit.Case, async: true

  alias ExTurso.Result
  alias ExTursoE2E.Support

  setup do
    {db, _pid} = Support.start_pool!(database: ":memory:", pool_size: 1)
    %{db: db}
  end

  test "round-trips supported scalar, null, boolean, and blob parameters", %{db: db} do
    Support.execute!(
      db,
      """
      CREATE TABLE values_roundtrip (
        id INTEGER PRIMARY KEY,
        integer_value INTEGER,
        real_value REAL,
        text_value TEXT,
        blob_value BLOB,
        null_value TEXT,
        true_value INTEGER,
        false_value INTEGER
      )
      """
    )

    blob = <<0, 1, 2, 255>>

    Support.execute!(
      db,
      "INSERT INTO values_roundtrip VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [1, 42, 3.25, "hello", blob, nil, true, false]
    )

    assert {:ok,
            %Result{
              rows: [
                %{
                  "integer_value" => 42,
                  "real_value" => 3.25,
                  "text_value" => "hello",
                  "blob_value" => ^blob,
                  "null_value" => nil,
                  "true_value" => 1,
                  "false_value" => 0
                }
              ]
            }} = ExTurso.query(db, "SELECT * FROM values_roundtrip WHERE id = ?", [1])
  end

  test "unsupported parameter types fail loudly", %{db: db} do
    unsupported_params = [:some_atom, [1, 2], %{a: 1}, 36_893_488_147_419_103_232]

    for param <- unsupported_params do
      assert {:error, %ExTurso.Error{code: :invalid_param, message: message}} =
               ExTurso.query(db, "SELECT ?", [param])

      assert message =~ "index 0"
    end
  end

  test "constraint errors expose the constraint code and leave the pool usable", %{db: db} do
    Support.execute!(db, "CREATE TABLE uniq (id INTEGER PRIMARY KEY, label TEXT UNIQUE NOT NULL)")
    Support.execute!(db, "INSERT INTO uniq VALUES (?, ?)", [1, "one"])

    assert {:error, %ExTurso.Error{code: :constraint}} =
             ExTurso.execute(db, "INSERT INTO uniq VALUES (?, ?)", [2, "one"])

    assert {:ok, %Result{rows: [%{"count" => 1}]}} =
             ExTurso.query(db, "SELECT count(*) AS count FROM uniq")
  end
end
