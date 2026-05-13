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

defmodule Prodigy.Server.Transport.Websocket do
  @moduledoc """
  TCS transport over a WebSocket. The "socket" value passed through TCS is
  the pid of the `WebSock` handler (see `Prodigy.Server.TcsWebSocket`):

    * `send/2` sends `{:tcs_out, iodata}` to the handler, which the handler
      converts into a binary WebSocket frame on its next scheduled tick.
    * `close/1` sends `:tcs_close`, prompting the handler to terminate the
      WebSocket with a normal close frame.

  The TCS GenServer doesn't know or care that its "socket" is actually an
  Elixir process - it calls `transport.send/close` the same way whether
  it's talking to a Ranch socket or a WebSock handler.
  """

  @behaviour Prodigy.Server.Transport

  @impl true
  def send(handler_pid, data) when is_pid(handler_pid) do
    Kernel.send(handler_pid, {:tcs_out, data})
    :ok
  end

  @impl true
  def close(handler_pid) when is_pid(handler_pid) do
    Kernel.send(handler_pid, :tcs_close)
    :ok
  end
end
