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

defmodule Prodigy.Server.Service.Enrollment do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle enrollment requests
  """

  require Logger
  require Ecto.Query

  import Ecto.Changeset

  alias Prodigy.Core.Data.{Household, Repo, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Service.{Logon, Messaging, Profile}
  alias Prodigy.Server.Context

  def handle(%Fm0{payload: payload} = request, %Context{user: user} = context) do
    Logger.debug("received enrollment packet: #{inspect(request, base: :hex, limit: :infinity)}")
    user_id = user.id

    <<0x2, type, 0x1, ^user_id::binary-size(7), _::40, _count::16-big, rest::binary>> = payload

    entries = Profile.parse_request_values(rest)
    household_changeset = Profile.get_household_changeset(entries)

    # propogate the subscriber given name/title to the related user account.  If the "user" data is
    # normalized out ouf the household, workarounds like this won't be needed.
    user_changeset =
      case type do
        0x2 ->  # user
          %{}

        0x1 ->  # subscriber
          %{
            last_name: Map.get(household_changeset, :user_a_last),
            first_name: Map.get(household_changeset, :user_a_first),
            middle_name: Map.get(household_changeset, :user_a_middle),
            title: Map.get(household_changeset, :user_a_title)
          }
      end
      |> Map.merge(Profile.get_user_changeset(entries))

    Repo.transaction(fn ->
      Repo.update(Household.changeset(user.household, household_changeset))

      Repo.update(
        user
        # _cast_ external data
        |> User.changeset(user_changeset)
        # _change_ internal data
        |> change(%{date_enrolled: Timex.today()})
      )
    end)

    user =
      User
      |> Ecto.Query.where(id: ^user_id)
      |> Ecto.Query.first()
      |> Ecto.Query.preload([:household])
      |> Repo.one()

    Messaging.send_message(
      "HELP99A",
      "Prodigy Help",
      [user.id],
      [],
      "Welcome!",
      "Welcome to Prodigy!"
    )

    response =
      Logon.make_response_payload({Logon.Status.SUCCESS, user})
      |> Fm0.make_response(request)
      |> DiaPacket.encode()

    Logger.info("Enrolled user #{user.id}")

    {:ok, %{context | user: user}, response}
  end
end
