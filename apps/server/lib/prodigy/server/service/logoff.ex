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

defmodule Prodigy.Server.Service.Logoff do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Logoff requests
  """

  require Logger
  require Ecto.Query
  import Ecto.Changeset

  alias Prodigy.Core.Data.{Repo, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Session

  defp clear_id_in_use(user_id, reason \\ "normal") do
    user =
      User
      |> Ecto.Query.where([u], u.id == ^user_id)
      |> Ecto.Query.first()
      |> Repo.one()

    # Because some pages specifically say "Eastern"
    now = Timex.now() |> Timex.Timezone.convert("US/Eastern")

    user
    |> change(%{
      logged_on: false,
      prf_last_logon_date: Timex.format!(now, "{0M}/{0D}/{YYYY}"),
      prf_last_logon_time: Timex.format!(now, "{h24}.{m}")
    })
    |> Repo.update()

    # TODO find the current session for the user and set the off time
    Logger.info("User #{user_id} logged off (#{reason})")
    :ok
  end

  # TODO better understand the format of this message
  def handle(%Fm0{} = request, %Session{user: nil}) do
    {:ok, %Session{}, DiaPacket.encode(Fm0.make_response(<<>>, request))}
  end

  def handle(%Fm0{dest: dest} = request, %Session{user: user}) do
    {:ok, result} =
      Repo.transaction(fn ->
        clear_id_in_use(user.id)

        case dest do
          0x00D201 -> :disconnect
          0x00D202 -> :ok
        end
      end)

    {result, %Session{},
     DiaPacket.encode(Fm0.make_response(<<0, "xxxxxxxx01011988124510">>, request))}
  end

  def handle_abnormal(nil) do
    :ok
  end

  def handle_abnormal(user) do
    clear_id_in_use(user.id, "abnormal")
    :ok
  end
end
