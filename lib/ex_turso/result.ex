defmodule ExTurso.Result do
  @moduledoc """
  The result of a query or statement.

    * `rows` — a list of maps keyed by column name (`nil` for non-`:query` commands)
    * `num_rows` — number of rows returned, or rows affected for writes
  """

  @type t :: %__MODULE__{
          rows: [map()] | nil,
          num_rows: non_neg_integer()
        }

  defstruct rows: nil, num_rows: 0
end
