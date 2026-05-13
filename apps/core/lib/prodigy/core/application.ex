# Copyright 2026, Phillip Heller
#
# This file is part of Prodigy Reloaded.
#
# Prodigy Reloaded is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# Prodigy Reloaded is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with Prodigy Reloaded. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Core.Application do
  @moduledoc """
  Supervises the shared Ecto Repo. Starting this application also starts
  the database connection pool, which lets dependent apps (server, portal,
  podbutil, pomsutil) or tests operate against the DB without each one
  owning the Repo.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      maybe_repo_child() ++
        [
          # Shared pubsub for cross-app runtime events (e.g. TCS session
          # logon/logoff) that one app publishes and another consumes. The
          # portal's Endpoint still uses Prodigy.Portal.PubSub for LiveView's
          # own channel machinery.
          {Phoenix.PubSub, name: Prodigy.Core.PubSub}
        ]

    opts = [strategy: :one_for_one, name: Prodigy.Core.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Only supervise the Repo when its config is present. Releases load it
  # via config/runtime.exs; escripts (pomsutil, podbutil) start the Repo
  # themselves via Prodigy.Core.Data.Util.start_repo/0 with env-driven
  # credentials, so auto-supervising here would crash them on core boot.
  defp maybe_repo_child do
    if Application.get_env(:core, Prodigy.Core.Data.Repo) do
      [Prodigy.Core.Data.Repo]
    else
      []
    end
  end
end
