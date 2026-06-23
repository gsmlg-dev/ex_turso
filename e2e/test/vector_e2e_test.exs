defmodule ExTursoE2E.VectorTest do
  use ExUnit.Case, async: true

  alias ExTursoE2E.Support

  setup do
    {db, _pid} = Support.start_pool!(database: ":memory:", pool_size: 1)
    %{db: db}
  end

  test "semantic search orders rows by cosine distance", %{db: db} do
    Support.execute!(
      db,
      "CREATE TABLE documents (id INTEGER PRIMARY KEY, title TEXT NOT NULL, embedding BLOB)"
    )

    Support.execute!(
      db,
      "INSERT INTO documents VALUES (?, ?, vector32(?))",
      [1, "databases", "[0.1, 0.3, 0.9, 0.2]"]
    )

    Support.execute!(
      db,
      "INSERT INTO documents VALUES (?, ?, vector32(?))",
      [2, "neural networks", "[0.25, 0.55, 0.15, 0.75]"]
    )

    assert %{"title" => "neural networks", "distance" => distance} =
             Support.query_one!(
               db,
               """
               SELECT title, vector_distance_cos(embedding, vector32(?)) AS distance
               FROM documents
               ORDER BY distance
               LIMIT 1
               """,
               ["[0.25, 0.55, 0.15, 0.75]"]
             )

    Support.assert_float_close(distance, 0.0)
  end

  test "vector creation and extraction functions work across supported encodings", %{db: db} do
    row =
      Support.query_one!(
        db,
        """
        SELECT
          vector_extract(vector32('[1.0, 2.0]')) AS f32,
          vector_extract(vector64('[1.0, 2.0]')) AS f64,
          vector_extract(vector8('[1.0, 2.0, 3.0]')) AS f8,
          vector_extract(vector1bit('[1.0, -1.0, 0.5]')) AS bit
        """
      )

    assert row["f32"] =~ "["
    assert row["f64"] =~ "2"
    assert row["f8"] =~ "3"
    assert row["bit"] =~ "1"
  end

  test "vector distance and utility functions are available", %{db: db} do
    row =
      Support.query_one!(
        db,
        """
        SELECT
          vector_distance_cos(vector32('[1.0, 0.0]'), vector32('[1.0, 0.0]')) AS cos,
          vector_distance_l2(vector32('[1.0, 1.0]'), vector32('[4.0, 5.0]')) AS l2,
          vector_distance_dot(vector32('[1.0, 2.0]'), vector32('[3.0, 4.0]')) AS dot,
          vector_distance_jaccard(
            vector32_sparse('[0.0, 1.0, 0.0, 2.0]'),
            vector32_sparse('[0.0, 1.0, 0.0, 2.0]')
          ) AS jaccard,
          vector_extract(vector_concat(vector32('[1.0, 2.0]'), vector32('[3.0, 4.0]'))) AS concat,
          vector_extract(vector_slice(vector32('[10.0, 20.0, 30.0, 40.0]'), 1, 3)) AS slice
        """
      )

    Support.assert_float_close(row["cos"], 0.0)
    Support.assert_float_close(row["l2"], 5.0)
    Support.assert_float_close(row["dot"], -11.0)
    Support.assert_float_close(row["jaccard"], 0.0)
    assert row["concat"] =~ "4"
    assert row["slice"] =~ "20"
    assert row["slice"] =~ "30"
  end
end
