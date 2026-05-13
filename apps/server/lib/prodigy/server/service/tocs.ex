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

defmodule Prodigy.Server.Service.Tocs do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle TOCS Object Requests
  """

  require Logger
  require Ecto.Query
  use EnumType
  import Bitwise

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.MissingObject
  alias Prodigy.Core.Data.Service.Object
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm64}
  alias Prodigy.Server.Protocol.Tocs.Packet, as: TocsPacket
  alias Prodigy.Server.Context

  def handle(
        %Fm0{
          message_id: message_id,
          payload: <<name::binary-size(11), sequence, type, rest::binary>>
        } = request,
        context \\ %Context{}
      ) do
    Logger.debug("received tocs packet: #{inspect(request, base: :hex)}")

    client_version =
      case rest do
        # this is masking off the top 3 bits for storage control; is this necessary?
        <<version::16-little>> -> version &&& 0x1FFF
        #      <<version::16-big>> -> version
        <<>> -> 0
      end

    user_request =
      "id: '#{name}\\#{inspect(sequence, base: :hex)}\\#{inspect(type, base: :hex)}' client_version: #{inspect(client_version, base: :hex)}"

    object =
      if String.printable?(name) do
        Object
        |> Ecto.Query.where([o], o.name == ^name)
        |> Ecto.Query.where([o], o.sequence == ^sequence)
        |> Ecto.Query.where([o], o.type == ^type)
        |> Ecto.Query.order_by([o], desc: o.version)
        |> Ecto.Query.first()
        |> Repo.one()
      else
        nil
      end

    response =
      cond do
        !String.printable?(name) ->
          Logger.warning("Client requested nonsensical object name #{inspect(name)}")

          fm64 = %Fm64{
            status_type: Fm64.StatusType.ERROR,
            data_mode: Fm64.DataMode.BINARY,
            payload: <<0xC>>
          }

          DiaPacket.encode(Fm0.make_response(<<>>, request, fm64))

        client_version == 0 and object == nil ->
          <<legend::binary-size(4), _identification::binary-size(4), extension::binary>> = name

          if String.trim(extension) == "D" and legend in ["XXMH", "XXME"] do
            record_deficit(name, sequence, type, context)
            <<candidacy_version_high::3, candidacy_version_low::13>> = <<0::3, 0::13>>

            TocsPacket.encode(%TocsPacket{
              seq: message_id,
              payload: <<
                name::binary-size(11),
                1,
                0x0C,
                55::16-little,
                candidacy_version_high,
                1,
                candidacy_version_low,
                0x61,
                37::16-little,
                0x2,
                "placeholder '#{name}' #{inspect(sequence, base: :hex)} #{inspect(type, base: :hex)}"
              >>
            })
          else
            record_deficit(name, sequence, type, context)

            fm64 = %Fm64{
              status_type: Fm64.StatusType.ERROR,
              data_mode: Fm64.DataMode.BINARY,
              payload: <<0xC>>
            }

            DiaPacket.encode(Fm0.make_response(<<>>, request, fm64))
          end

        object == nil ->
          record_deficit(name, sequence, type, context)
          TocsPacket.encode(%TocsPacket{seq: message_id})

        client_version < object.version or client_version == 0 ->
          Logger.debug(
            "User requested #{user_request}, sending database version #{inspect(object.version, base: :hex)}"
          )

          tocs_response = %TocsPacket{seq: message_id, payload: object.contents}
          TocsPacket.encode(tocs_response)

        client_version > object.version ->
          Logger.notice(
            "User requested #{user_request}, but it is newer than the database version (#{inspect(object.version, base: :hex)})"
          )

          TocsPacket.encode(%TocsPacket{seq: message_id})

        client_version == object.version ->
          TocsPacket.encode(%TocsPacket{seq: message_id})

        true ->
          Logger.error("Unhandled condition #{client_version}, #{inspect(object)}")
          <<>>
      end

    {:ok, context, response}
  end

  # Upsert into missing_objects so the deficit shows up on
  # /admin/service/objects/deficits even though we couldn't serve it.
  # Errors are swallowed (logged at warning) - we never want a write
  # failure to gate the user-facing TOCS response.
  defp record_deficit(name, sequence, type, %Context{} = context) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    user_id =
      case context.user do
        %{id: id} when is_binary(id) -> id
        _ -> nil
      end

    attrs = %{
      name: name,
      sequence: sequence,
      type: type,
      first_seen: now,
      last_seen: now,
      last_user_id: user_id,
      last_session_id: context.session_id,
      hit_count: 1
    }

    try do
      MissingObject.observation_changeset(attrs)
      |> Repo.insert(
        on_conflict: [
          set: [last_seen: now, last_user_id: user_id, last_session_id: context.session_id],
          inc: [hit_count: 1]
        ],
        conflict_target: [:name, :sequence, :type]
      )
    rescue
      e ->
        Logger.warning("missing_objects upsert failed: #{Exception.message(e)}")
    end

    :ok
  end
end
