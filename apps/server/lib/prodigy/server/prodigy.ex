# Copyright 2022, Phillip Heller
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

defmodule Prodigy.Server.Application do
  @moduledoc """
  The entry point for the Prodigy Delivery System, aka `prodigyd`.
  """

  use Application
  require Logger

  @doc """
  Start supervision tree and Delivery System components.
  """
  @impl Application
  def start(_type, _args) do
    Logger.info("Starting Prodigy Server")

    children = [
      {Prodigy.Server.RanchSup, {}},
      {Prodigy.Core.Data.Repo, []},
      Prodigy.Server.Scheduler
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
