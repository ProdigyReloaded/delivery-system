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

defmodule Prodigy.Server.Service.AddressBook do
  @behaviour Prodigy.Server.Service
  @moduledoc false

  require Logger

  alias Prodigy.Server.Session
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket

  def handle(%Fm0{payload: <<0xD, payload::binary>>} = request, %Session{} = session) do
    response =
      case payload do
        # this is sent when jumping to "address book"; unsure what it is
        # TODO address book sends this on entry, why?
        <<0xF>> ->
          :ok

        # TODO determine personal address book response
        <<0x1>> ->
          {:ok, <<0x01, 0x03, "FOO">>}

        # TODO determine mailing list response
        <<0x6>> ->
          {:ok, <<0x01, 0x03, "FOO">>}

        _ ->
          Logger.warn(
            "unhandled addressbook request #{inspect(request, base: :hex, limit: :infinity)}"
          )

          {:ok, <<>>}
      end

    case response do
      {:ok, payload} -> {:ok, session, DiaPacket.encode(Fm0.make_response(payload, request))}
      _ -> {:ok, session}
    end
  end
end
