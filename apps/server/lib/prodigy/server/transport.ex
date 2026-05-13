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

defmodule Prodigy.Server.Transport do
  @moduledoc """
  The byte-delivery layer under TCS. Each implementation wraps a specific
  framing + wire combination:

    * `Prodigy.Server.Transport.Tcp` - raw TCP, no extra framing. Socket is
      a Ranch-managed :gen_tcp socket.
    * `Prodigy.Server.Transport.Websocket` - RFC 6455 frames over HTTP/TCP.
      Socket is the pid of the `WebSock` handler; send/close are delivered
      as messages the handler translates into outbound frames.
    * (future) `Prodigy.Server.Transport.Xot` - X.25 over TCP (RFC 1613),
      for period-authentic hardware gateways. Not implemented yet; naming
      the future sibling here to make sure the abstraction shape doesn't
      lock it out.

  TCS only ever calls `transport.send/2` and `transport.close/1`, so the
  transport module is orthogonal to the protocol state machine.
  """

  @callback send(socket :: any, data :: iodata) :: :ok | {:error, term}
  @callback close(socket :: any) :: :ok
end
