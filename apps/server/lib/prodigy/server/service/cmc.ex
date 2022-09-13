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

defmodule Prodigy.Server.Service.Cmc do
  @behaviour Prodigy.Server.Service
  @moduledoc false

  require Logger

  alias Prodigy.Server.Session
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm9}

  # TODO better understand the format of this message
  def handle(%Fm0{payload: %Fm9{payload: _payload}} = request, %Session{} = session) do
    Logger.debug("cmc got #{inspect(request, base: :hex, limit: :infinity)}")

    # will have an FM9 header, not concatenated
    # function code = 3 (alert)
    # reason code = 2 (reception-oriented)
    # flags = 0x90 (store by key, ascii)
    # text length

    # architected text:

    #    <<
    #      user_id::binary-size(7),          # right padded with '?'
    #      "  ",
    #      system_origin,                    # "T" = Trintex
    #      msg_origin::binary-size(3),       # "PCM" = pcmessage
    #      unit_id::binary-size(2),          # ascii decimals, "10" typical
    #      error_code::binary-size(2),       # ascii decimals, "02" typical
    #      severity_level,                   # 'E'
    #      " ",
    #      error_threshold::binary-size(3),  # "001"
    #      " ",
    #      date::binary-size(8),             # '05231988' typical
    #      time::binary-size(6),             # '143023' typical
    #      api_event::binary-size(5),        # '00003' typical
    #      mem_to_start::binary-size(8),     # '00227472' typical
    #      dos_version::binary-size(5),      # '03.30' typical
    #      rs_version::binary-size(8),       # '6.01.XX' typical
    #      window_id::binary-size(11),       # 'NOWINDOWIDX' typical
    #      window_last::binary-size(2),      # in ascii hex, '0104' typical
    #      selected_id::binary-size(11),     # 'NOSELECTORX' typical
    #      selected_last::binary-size(4),    # '0104 typical
    #      base_id::binary-size(11),         # 'PIOT0010MAP' typical
    #      base_last::binary-size(2),        # '0104' typical
    #      keyword::binary-size(13)          # 'QUOTE TRACK  ' typical
    #    >>

    {:ok, session, <<>>}
  end
end
