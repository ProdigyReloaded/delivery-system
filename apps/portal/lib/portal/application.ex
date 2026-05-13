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

defmodule Prodigy.Portal.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Prodigy.Portal.Telemetry,
      {Phoenix.PubSub, name: Prodigy.Portal.PubSub},
      {Task.Supervisor, name: Prodigy.Portal.TaskSupervisor},
      Prodigy.Portal.Accounts.RateLimit,
      Prodigy.Portal.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Prodigy.Portal.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Prodigy.Portal.Endpoint.config_change(changed, removed)
    :ok
  end
end
