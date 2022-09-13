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

defmodule Prodigy.Server.Service.Ads do
  @behaviour Prodigy.Server.Service
  @moduledoc false

  require Logger

  alias Prodigy.Server.Session
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0, as: Fm0
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket

  # TODO better understand the format of this message
  def handle(%Fm0{} = request, %Session{} = session) do
    # payload on login to DIA DID 0xD200 is \x02\x56
    Logger.debug("ads requested")

    payload = <<
      0x02,
      0x0A,
      "AD000001LDR"::binary,
      0x00,
      0x08,
      "AOL00000LDR"::binary,
      0x00,
      0x08,
      #        "AD000002LDR"::binary, 0x00, 0x08,
      "AD000003LDR"::binary,
      0x00,
      0x08,
      "AD000004LDR"::binary,
      0x00,
      0x08,
      "AD000005LDR"::binary,
      0x00,
      0x08,
      "AD000006LDR"::binary,
      0x00,
      0x08,
      "AD000007LDR"::binary,
      0x00,
      0x08,
      "AD000008LDR"::binary,
      0x00,
      0x08,
      "AD000009LDR"::binary,
      0x00,
      0x08,
      "AD000010LDR"::binary,
      0x00,
      0x08
    >>

    {:ok, session, DiaPacket.encode(Fm0.make_response(payload, request))}
  end
end
