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

defmodule Prodigy.Server.Service.DataCollection do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle data collection messages
  """

  require Logger

  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Session

  defmodule ObjectRecord do
    @moduledoc false
    defstruct [:rec_type, :object_name, :seq, :type, :minutes, :seconds]
  end

  defmodule FunctionRecord do
    @moduledoc false
    defstruct [:class, :minutes, :seconds]
  end

  defp parse(data, entries \\ [])

  defp parse(
         <<0x0, 0x48, rec_type, _len, object_name::binary-size(11), seq, type, minutes, seconds,
           rest::binary>>,
         entries
       ) do
    parse(
      rest,
      entries ++
        [
          %ObjectRecord{
            rec_type: rec_type,
            object_name: object_name,
            seq: seq,
            type: type,
            minutes: minutes,
            seconds: seconds
          }
        ]
    )
  end

  defp parse(<<0x0, 0x49, class, minutes, seconds, rest::binary>>, entries) do
    parse(rest, entries ++ [%FunctionRecord{class: class, minutes: minutes, seconds: seconds}])
  end

  defp parse(<<>>, entries) do
    entries
  end

  def handle(%Fm0{dest: _dest, payload: <<0x4, rest::binary>>} = request, %Session{} = session) do
    Logger.debug("data collection request #{inspect(request, base: :hex, limit: :infinity)}")

    entries = parse(rest)

    Logger.debug("data collection records: #{inspect(entries, pretty: true)}")

    # TODO log these to a database and associate with relevant user session
    {:ok, session}
  end
end
