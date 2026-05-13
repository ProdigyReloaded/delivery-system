Application.ensure_all_started(:core)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Prodigy.Core.Data.Repo, :manual)
