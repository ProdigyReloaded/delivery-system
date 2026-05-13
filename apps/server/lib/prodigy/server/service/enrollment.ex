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

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Service.{Logon, Messaging, Profile}
  alias Prodigy.Server.Context

  def handle(%Fm0{payload: payload} = request, %Context{user: user} = context) do
    Logger.debug("received enrollment packet: #{inspect(request, base: :hex, limit: :infinity)}")
    user_id = user.id

    # The RS enrollment flow tells the subscriber that any additional
    # household members they register here will use the *same initial
    # password that was issued to the subscriber* - i.e., the welcome-kit
    # credential they logged in with, NOT a new password they may choose
    # during this enrollment (TAC 0x014F). Capture it now, before the
    # changeset pipeline can stage the new password.
    subscriber_initial_password = user.password

    <<0x2, type, 0x1, ^user_id::binary-size(7), _::40, _count::16-big, rest::binary>> = payload

    entries = Profile.parse_request_values(rest)

    # Route the wire entries through the unified ProfileDispatch path so
    # top-level User fields (notably :password via TAC 0x014F, which
    # User.changeset/2 hashes via put_password_hash) make it onto the
    # changeset alongside the JSONB :profile patch. `member_patches`
    # carries the name/title data for household slots B..F so we can
    # materialize the per-slot User rows (AAAA11B..F) below.
    {user_cs, household_cs, member_patches} =
      Profile.build_changesets(entries, user, user.household)

    # A subscriber enrollment (type 0x1) writes the name/title into the
    # household's A slot (TACs 0x011A..0x011D). Mirror those into the
    # user's own name TACs (0x015E..0x0161) so user.profile carries the
    # same data - User.first_name/1, full_name/1, and the admin display
    # depend on it. Non-subscriber users (type 0x2) send user-direct
    # TACs in `entries` and don't need the mirror.
    user_cs =
      case type do
        0x1 -> apply_slot_a_mirror(user_cs, household_cs)
        _ -> user_cs
      end

    user_cs = user_cs |> change(date_enrolled: Timex.today())

    Repo.transaction(fn ->
      if household_cs, do: Repo.update!(household_cs)

      # Create the member rows with the subscriber's *original* initial
      # password, before applying the subscriber's own (possibly new)
      # password via user_cs.
      if user.household && map_size(member_patches) > 0 do
        Profile.persist_members(member_patches, user.household, subscriber_initial_password)
      end

      Repo.update!(user_cs)
    end)

    # Let admin views refresh the name/title fields that just landed.
    Prodigy.Server.SessionManager.broadcast_profile_updated(user.id)

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
      Logon.make_response_payload({Logon.Status.SUCCESS, user, context.session_id})
      |> Fm0.make_response(request)
      |> DiaPacket.encode()

    Logger.info("Enrolled user #{user.id}")

    {:ok, %{context | user: user}, response}
  end

  # Read the household changeset's :profile change (if any), pull the
  # slot-A name keys, and merge their values under the user's own name
  # TACs into the user changeset's :profile change. Returns the user
  # changeset unchanged when there's nothing to mirror.
  defp apply_slot_a_mirror(user_cs, nil), do: user_cs

  defp apply_slot_a_mirror(user_cs, household_cs) do
    hh_profile = get_change(household_cs, :profile) || %{}
    slot = Household.slot_keys("a")

    mirror =
      %{}
      |> maybe_put(hh_profile, slot.last, "015E")
      |> maybe_put(hh_profile, slot.first, "015F")
      |> maybe_put(hh_profile, slot.middle, "0160")
      |> maybe_put(hh_profile, slot.title, "0161")

    if map_size(mirror) == 0 do
      user_cs
    else
      current = get_change(user_cs, :profile) || %{}
      put_change(user_cs, :profile, Map.merge(current, mirror))
    end
  end

  defp maybe_put(acc, source, source_key, dest_key) do
    case Map.get(source, source_key) do
      nil -> acc
      value -> Map.put(acc, dest_key, value)
    end
  end
end
