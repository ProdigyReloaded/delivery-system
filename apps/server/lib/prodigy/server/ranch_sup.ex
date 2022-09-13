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

defmodule Prodigy.Server.RanchSup do
  @moduledoc false

  use Supervisor
  require Logger
  alias Prodigy.Server.Protocol.Tcs.Options

  def start_link(args) do
    Logger.debug("starting the ranch supervisor")
    Supervisor.start_link(__MODULE__, args)
  end

  @impl Supervisor
  def init({}) do
    Logger.debug("setting up the ranch supervision tree")

    children = [
      {Prodigy.Server.TcsListener, [[{:port, 25_234}], %Options{}]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
