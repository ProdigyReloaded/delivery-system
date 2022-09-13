# Copyright 2022, Phillip Heller
#
# This file is part of prodigyd.
#
# prodigyd is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# prodigyd is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with prodigyd. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Server.Application do
  @moduledoc false

  use Application
  require Logger

  @impl Application
  def start(_type, _args) do
    Logger.info("Starting Prodigy Server")

    children = [
      {Prodigy.Server.RanchSup, {}},
      {Prodigy.Core.Data.Repo, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
