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

defmodule Prodigy.Server.Service.Cmc do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle error messages to the CMC
  """

  require Logger

  alias Prodigy.Server.Session
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm9}

  def handle(%Fm0{fm9: %Fm9{payload: payload}} = request, %Session{} = session) do
    Logger.debug("cmc got #{inspect(request, base: :hex, limit: :infinity)}")

    # TODO insert the error details into the database

    case payload do
        <<
          user_id::binary-size(7),          # right padded with '?'
          _spaces1::binary-size(2),         # "  ",
          ## "  ",
          system_origin::binary-size(1),    # "T" = Trintex
          msg_origin::binary-size(3),       # "PCM" = pcmessage
          unit_id::binary-size(2),          # ascii decimals, "10" typical
          error_code::binary-size(2),       # ascii decimals, "02" typical
          severity_level::binary-size(1),   # 'E'
          _spaces2::binary-size(1),
          ## " ",
          error_threshold::binary-size(3),  # "001"
          _spaces3::binary-size(1),
          ## " ",
          date::binary-size(8),             # '05231988' typical
          time::binary-size(6),             # '143023' typical
          api_event::binary-size(5),        # '00003' typical
          mem_to_start::binary-size(8),     # '00227472' typical
          dos_version::binary-size(5),      # '03.30' typical
          rs_version::binary-size(7),       # '6.01.XX' typical
          _spaces4::binary-size(1),
          ## " ",
          window_id::binary-size(11),       # 'NOWINDOWIDX' typical
          window_last::binary-size(4),      # in ascii hex, '0104' typical
          selected_id::binary-size(11),     # 'NOSELECTORX' typical
          selected_last::binary-size(4),    # '0104 typical
          base_id::binary-size(11),         # 'PIOT0010MAP' typical
          base_last::binary-size(4),        # '0104' typical
          keyword::binary-size(13)          # 'QUOTE TRACK  ' typical
        >> ->
          msg = """
          CMC FM9 Error reported by Reception System

                  User ID: #{user_id}
            System Origin: #{system_origin}
           Message Origin: #{msg_origin}
                  Unit ID: #{unit_id}
               Error Code: #{error_code}
           Severity Level: #{severity_level}
          Error Threshold: #{error_threshold}
                     Date: #{date}
                     Time: #{time}
                API Event: #{api_event}
             Starting RAM: #{mem_to_start}
              DOS Version: #{dos_version}
               RS Version: #{rs_version}
                Window ID: #{window_id}
              Window Last: #{inspect window_last, base: :hex}
              Selected ID: #{selected_id}
            Selected Last: #{inspect selected_last, base: :hex}
                  Base ID: #{base_id}
                Base Last: #{inspect base_last, base: :hex}
                  Keyword: #{keyword}
          """
          Logger.warning(msg)
        _ ->
          Logger.warning("CMC received message in unknown format: #{inspect payload, base: :hex, limit: :infinity}")
      end

    {:ok, session, <<>>}
  end
end
