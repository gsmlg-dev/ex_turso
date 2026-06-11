defmodule ExTurso.MixProject do
  use Mix.Project

  @source_url "https://github.com/gsmlg-dev/ex_turso"

  def project do
    [
      app: :ex_turso,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description: "DBConnection-backed Elixir wrapper for Turso/libSQL via Rustler",
      source_url: @source_url,
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.32"},
      {:db_connection, "~> 2.7"}
    ]
  end

  defp package do
    [
      maintainers: ["Jonathan Gao"],
      licenses: ["MIT"],
      files: [
        ".formatter.exs",
        "lib",
        "mix.exs",
        "native/ex_turso/Cargo.lock",
        "native/ex_turso/Cargo.toml",
        "native/ex_turso/src",
        "README.md",
        "LICENSE"
      ],
      links: %{"GitHub" => @source_url}
    ]
  end
end
