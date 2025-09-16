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

  alias Prodigy.Core.Data.{CmcError, Repo}
  alias Prodigy.Server.Context
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm9}

  def handle(%Fm0{fm9: %Fm9{payload: payload}}, %Context{} = context) do
    case payload do
        <<
          user_id::binary-size(7),          # right padded with '?'
          "  ",
          system_origin::binary-size(1),    # "T" = Trintex
          msg_origin::binary-size(3),       # "PCM" = pcmessage
          unit_id::binary-size(2),          # ascii decimals, "10" typical
          error_code::binary-size(2),       # ascii decimals, "02" typical
          severity_level::binary-size(1),   # 'E'
          " ",
          error_threshold::binary-size(3),  # "001"
          " ",
          date::binary-size(8),             # '05231988' typical
          time::binary-size(6),             # '143023' typical
          api_event::binary-size(5),        # '00003' typical
          mem_to_start::binary-size(8),     # '00227472' typical
          dos_version::binary-size(5),      # '03.30' typical
          rs_version::binary-size(7),       # '6.01.XX' typical
          " ",
          window_id::binary-size(11),       # 'NOWINDOWIDX' typical
          window_last::binary-size(4),      # in ascii hex, '0104' typical
          selected_id::binary-size(11),     # 'NOSELECTORX' typical
          selected_last::binary-size(4),    # '0104 typical
          base_id::binary-size(11),         # 'PIOT0010MAP' typical
          base_last::binary-size(4),        # '0104' typical
          keyword::binary-size(13)          # 'QUOTE TRACK  ' typical
        >> ->
          # Insert the CMC error into the database
          cmc_result = %CmcError{}
          |> CmcError.changeset(%{
            session_id: context.session_id,  # Assuming session_id is in context
            user_id: user_id,
            system_origin: system_origin,
            msg_origin: msg_origin,
            unit_id: unit_id,
            error_code: error_code,
            severity_level: severity_level,
            error_threshold: error_threshold,
            error_date: date,
            error_time: time,
            api_event: api_event,
            mem_to_start: mem_to_start,
            dos_version: dos_version,
            rs_version: rs_version,
            window_id: window_id,
            window_last: window_last,
            selected_id: selected_id,
            selected_last: selected_last,
            base_id: base_id,
            base_last: base_last,
            keyword: keyword,
            raw_payload: payload
          })
          |> Repo.insert()

          case cmc_result do
            {:ok, _} ->
              Logger.error("CMC error logged from #{user_id}: code=#{error_code}, severity=#{severity_level}")

            {:error, changeset} ->
              Logger.error("Failed to log CMC error: #{inspect(changeset.errors)}")
          end

      _ ->
        Logger.warning("CMC received malformed error payload: #{inspect(payload, base: :hex)}")

    end

    {:ok, context, <<>>}
  end
end