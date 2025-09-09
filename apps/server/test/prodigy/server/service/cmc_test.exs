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

defmodule Prodigy.Server.Service.Cmc.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase

  import ExUnit.CaptureLog

  require Logger

  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm9}
  alias Prodigy.Server.Protocol.Dia.Packet.Fm9.{Flags, Function, Reason}
  alias Prodigy.Server.Router

#  @moduletag :capture_log

  setup do
    {:ok, router_pid} = GenServer.start_link(Router, nil)

    [router_pid: router_pid]
  end

  test "error report", context do
    fm0 = %Fm0{
      concatenated: true,
      src: 0x0,
      dest: 0x020200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<>>,
      mode: %Fm0.Mode{
        compaction: false,
        encryption: false,
        logging_required: false,
        reserved: false,
        response: false,
        response_expected: false,
        timeout_message_required: false,
        unsolicited_message: false
      },
      fm9: %Fm9{
        concatenated: false,
        function: Function.ALERT,
        reason: Reason.RECEPTION_SYSTEM,
        flags: %Flags{
          store_by_key: true,
          retrieve_by_key: false,
          binary_data: false,
          ascii_data: true
        },
        payload: <<
          "AAAA12A",
          "  ",
          "T",
          "PCM",
          "10",
          "02",
          "E",
          " ",
          "001",
          " ",
          "05231988",
          "143023",
          "00003",
          "00227472",
          "03.30",
          "6.01.XX",
          " ",
          "NOWINDOWIDX",
          "0104",
          "NOSELECTORX",
          "0104",
          "PIOT0010MAP",
          "0104",
          "QUOTE TRACK  "
        >>
      }
    }

    assert capture_log([level: :warn], fn ->
           Router.handle_packet(context.router_pid, fm0)
    end) =~ "CMC FM9"

    # TODO assert the message was inserted into the database
  end
end
