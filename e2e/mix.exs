defmodule ExTursoE2E.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_turso_e2e,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    case System.get_env("EX_TURSO_VERSION") do
      nil -> [{:ex_turso, path: ex_turso_path()}]
      version -> [{:ex_turso, "== #{version}"}]
    end
  end

  defp ex_turso_path do
    System.get_env("EX_TURSO_PATH") || Path.expand("..", __DIR__)
  end
end
