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

defmodule Prodigy.Server.Service.DataCollection do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle data-collection messages from the RS client. Parses the
  stream of ObjectRecord (0x48) and FunctionRecord (0x49) entries,
  persists each as a `%DataCollectionEvent{}`, and broadcasts a
  `Prodigy.Core.ServiceEvents` message per row so the admin Events
  feed can surface them live.
  """

  require Logger

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.DataCollectionEvent
  alias Prodigy.Core.ServiceEvents
  alias Prodigy.Server.Context
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0

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

  def handle(%Fm0{dest: _dest, payload: <<0x4, rest::binary>>} = request, %Context{} = context) do
    Logger.debug("data collection request #{inspect(request, base: :hex, limit: :infinity)}")

    entries = parse(rest)
    Enum.each(entries, &persist_and_broadcast(&1, context))

    {:ok, context}
  end

  defp persist_and_broadcast(record, context) do
    attrs = attrs_for(record, context)

    case %DataCollectionEvent{}
         |> DataCollectionEvent.changeset(attrs)
         |> Repo.insert() do
      {:ok, row} ->
        ServiceEvents.broadcast_data_collection(row)

      {:error, cs} ->
        Logger.error(
          "data_collection insert failed for #{inspect(record)}: #{inspect(cs.errors)}"
        )
    end
  end

  defp attrs_for(%ObjectRecord{} = r, context) do
    %{
      session_id: context.session_id,
      user_id: user_id_from(context),
      kind: "object",
      object_name: r.object_name,
      object_sequence: r.seq,
      object_type: r.type,
      record_type: r.rec_type,
      duration_seconds: r.minutes * 60 + r.seconds
    }
  end

  defp attrs_for(%FunctionRecord{} = r, context) do
    %{
      session_id: context.session_id,
      user_id: user_id_from(context),
      kind: "function",
      function_class: r.class,
      duration_seconds: r.minutes * 60 + r.seconds
    }
  end

  defp user_id_from(%Context{user: %{id: id}}) when is_binary(id), do: id
  defp user_id_from(_), do: "unknown"
end
