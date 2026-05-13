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

defmodule Prodigy.Core.ServiceEvents do
  @moduledoc """
  Lightweight PubSub shim for service-side log events. Producers -
  the server app's Cmc, DataCollection, and SessionManager modules -
  call the `broadcast_*/1` helpers when they persist a row. The
  admin portal's `Prodigy.Portal.Admin.ServiceEvents` subscribes
  here and does the heavier work of mapping each row to its
  common event shape for the table.

  This module intentionally lives in core so both sides can use it
  without creating a server -> portal dependency. It's just a typed
  wrapper around Phoenix.PubSub; all shape decisions (`:at`,
  `:summary`, detail rendering) belong to the portal consumer.

  Broadcast payloads:

    * `{:service_event, {:logon,  %Session{}}}`
    * `{:service_event, {:logoff, %Session{}}}`
    * `{:service_event, {:cmc, %CmcError{}}}`
    * `{:service_event, {:data_collection, %DataCollectionEvent{}}}`
  """
  @pubsub Prodigy.Core.PubSub
  @topic "service:events"

  @doc "PubSub topic subscribers listen on."
  def topic, do: @topic

  @doc "Subscribe the current process to service events."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc "Unsubscribe from service events."
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(@pubsub, @topic)

  @doc "Broadcast a service-event payload. Safe from any process; never raises."
  def broadcast(payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:service_event, payload})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def broadcast_logon(session), do: broadcast({:logon, session})
  def broadcast_logoff(session), do: broadcast({:logoff, session})
  def broadcast_cmc_error(row), do: broadcast({:cmc, row})
  def broadcast_data_collection(row), do: broadcast({:data_collection, row})
end
