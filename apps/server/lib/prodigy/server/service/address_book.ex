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

defmodule Prodigy.Server.Service.AddressBook do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Address Book Retrieval and Update requests
  """

  require Logger

  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Session

  def handle(%Fm0{payload: <<0xD, payload::binary>>} = request, %Session{} = session) do
    response =
      case payload do
        # this is sent when jumping to "address book"; unsure what it is
        <<0xF>> ->
          :ok

        # personal address book request
        <<0x1>> ->
          {:ok, <<0x01, 0x03, "TODO">>}

        # mailing list request
        <<0x6>> ->
          {:ok, <<0x01, 0x03, "TODO">>}

        _ ->
          Logger.warning(
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
