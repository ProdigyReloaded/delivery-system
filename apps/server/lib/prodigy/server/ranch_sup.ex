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

defmodule Prodigy.Server.RanchSup do
  @moduledoc """
  This is the base supervisor for all TCP connections to prodigyd.
  """

  use Supervisor
  require Logger
  import Cachex.Spec
  alias Prodigy.Server.Protocol.Tcs.Options

  def start_link(args) do
    Logger.debug("starting the ranch supervisor")
    Supervisor.start_link(__MODULE__, args)
  end

  @doc """
  Start a child supervisor that listens for incoming TCP connections on the specified port.
  """
  @impl Supervisor
  def init({}) do

    Logger.debug("Setting up Down Jones company name lookup")
    :ets.new(:dow_jones, [:set, :public, :named_table])

    Logger.debug("Setting up cache for transmitting packets")
    Cachex.start_link(:transmit, [
      expiration: expiration(
        # how often cleanup should occur
        interval: :timer.seconds(15),

        # default record expiration
        default: :timer.seconds(60)
      )
    ])

    Logger.debug("Setting up cache for tracking acks")
    Cachex.start_link(:ack_tracker, [
      expiration: expiration(
        # how often cleanup should occur
        interval: :timer.seconds(15),

        # default record expiration
        default: :timer.minutes(2)
      )
    ])

    Logger.debug("setting up the ranch supervision tree")

    children = [
      {Prodigy.Server.TcsListener, [[{:port, 25_234}], %Options{}]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
