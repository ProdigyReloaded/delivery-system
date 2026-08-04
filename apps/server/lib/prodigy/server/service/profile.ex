# Copyright 2022-2026, Phillip Heller and Ralph Richard Cook
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

defmodule Prodigy.Server.Service.Profile do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Profile Requests. Routes TAC reads/writes through
  `Prodigy.Core.Data.Service.ProfileDispatch`, which resolves each
  TAC to the right record + JSONB key per `ProfileSchema`.
  """

  require Logger
  require Ecto.Query
  use EnumType

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, ProfileBackfill, ProfileDispatch, ProfileSchema, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context

  # Transient companion TAC (never stored): its presence in a profile
  # write means "verify this old password before applying the rest".
  @verify_old_pw_tac 0x015D

  # PRF_COUNT_PASSWORD_CHANGE_TRYS (#340 / 0x0154, per-user, 1 char): the
  # server-authoritative failed-old-password counter for the service change-
  # password flow. Incremented here on a rejected verify, reset to 0 on a
  # successful password change, and enforced here - a modified client cannot
  # bypass it (the old client-side counter in TOOT111E/H is gone).
  @try_count_key "0154"
  @max_password_change_trys 3

  @doc """
  Decode wire bytes back into the list of `{tac, value}` tuples the
  client sent.
  """
  def parse_request_values(payload, entries \\ [])
  def parse_request_values(<<>>, entries), do: entries

  def parse_request_values(payload, entries) do
    <<tac::16-big, length, value::binary-size(length), rest::binary>> = payload
    parse_request_values(rest, entries ++ [{tac, value}])
  end

  @doc """
  Serialize one TAC's value for a retrieve response. Returns the
  tag-length-value on-wire encoding.
  """
  def get_tac(tac, user, household) do
    res = get_value(tac, user, household)

    <<tac::16-big>> <>
      case res do
        nil ->
          <<0x0>>

        "" ->
          <<0x0>>

        " " ->
          <<0x0>>

        binary when is_binary(binary) ->
          <<byte_size(binary), binary::binary>>

        other ->
          s = to_string(other)
          <<byte_size(s), s::binary>>
      end
  end

  # "hardcoded" TACs for Eaasy Sabre - these are not in the registry
  def get_value(0x183, _user, _household), do: "0ABC123" # this is the AA freq flier number

  def get_value(0x18A, _user, _household), do: "     " # this, I think, is the travel agent id; blank for none

  @doc """
  Read the current value for a TAC. Household member slots B..F are
  read through to the per-slot User row (`household.id <> slot`); the
  rest go through `ProfileDispatch.get_value/3`. Logs a warning for
  unknown TACs so gap-hunting against the registry doesn't crash the
  client.
  """
  def get_value(tac, user, household) do
    if not ProfileSchema.known?(tac) do
      Logger.warning(
        "[profile] unknown TAC #{inspect(tac, base: :hex)} requested; returning empty"
      )
    end

    case ProfileSchema.slot_member_tac(tac) do
      {slot, user_tac} when slot in ~w(B C D E F) ->
        member_value(household, slot, user_tac)

      _ ->
        ProfileDispatch.get_value(tac, user, household)
    end
  end

  # Read a slot-B..F member's name/title TAC from its own User row.
  # These TACs are all :ascii so no decode is needed. Missing member
  # row or empty value -> " " (the same sentinel ProfileDispatch uses).
  defp member_value(nil, _slot, _user_tac), do: " "

  defp member_value(%Household{} = household, slot, user_tac) do
    case Repo.get(User, household.id <> slot) do
      nil ->
        " "

      %User{} = member ->
        case Map.get(member.profile || %{}, ProfileBackfill.tac_key(user_tac)) do
          v when is_binary(v) and v != "" -> v
          _ -> " "
        end
    end
  end

  @doc """
  Build the user/household changesets plus the per-slot member patches
  for the incoming wire entries. Returns
  `{user_changeset_or_nil, household_changeset_or_nil, member_patches}`
  where `member_patches` is `%{slot_letter => %{user_own_tac_key => value}}`
  for slots B..F (slot A is the subscriber, handled by the caller).
  Callers run the changesets in a transaction and pass `member_patches`
  to `persist_members/3`.

  Writes target the JSONB `profile` map. The household user-slot fields
  (0x011A..0x014D) still land on `household.profile` as a denormalized
  mirror; the same name/title data is also accumulated into
  `member_patches` so the caller can materialize the per-slot User rows
  (AAAA11B..F) keyed off `household.id <> slot`.
  """
  def build_changesets(entries, %User{} = user, household) do
    %{user: updated_user, household: updated_hh} =
      ProfileDispatch.apply_entries(entries, user, household)

    user_changeset = User.changeset(user, changes_map(user, updated_user))

    household_changeset =
      if is_nil(household) do
        nil
      else
        Household.changeset(household, changes_map(household, updated_hh))
      end

    {user_changeset, household_changeset, member_patches(entries)}
  end

  # Scan the wire entries for household user-slot name/title TACs whose
  # slot is B..F (slot A == the subscriber, handled separately), and
  # group them by slot into `%{slot => %{user_own_tac_key => value}}`.
  defp member_patches(entries) do
    Enum.reduce(entries, %{}, fn {tac, value}, acc ->
      case ProfileSchema.slot_member_tac(tac) do
        {slot, user_tac} when slot in ~w(B C D E F) ->
          key = ProfileBackfill.tac_key(user_tac)
          Map.update(acc, slot, %{key => value}, &Map.put(&1, key, value))

        _ ->
          acc
      end
    end)
  end

  @doc """
  Materialize the per-slot member User rows from `member_patches`
  (output of `build_changesets/3`). For each populated slot it
  find-or-creates `User{id: household.id <> slot}`: a new row is created
  un-enrolled (so the member's first logon routes to
  `Logon.Status.ENROLL_OTHER`) with `password` copied from the
  subscriber; an existing row gets the patch merged into its `profile`.
  Must run inside the caller's `Repo.transaction`. Returns the list of
  created/updated member ids.
  """
  def persist_members(member_patches, %Household{} = household, subscriber_password) do
    for {slot, patch} <- member_patches, map_size(patch) > 0 do
      member_id = household.id <> slot

      case Repo.get(User, member_id) do
        nil ->
          %User{id: member_id, household_id: household.id}
          |> User.changeset(%{profile: patch, password: subscriber_password})
          |> Repo.insert!()

          Logger.info("Created household member #{member_id}")
          member_id

        %User{} = member ->
          member
          |> User.changeset(%{profile: Map.merge(member.profile || %{}, patch)})
          |> Repo.update!()

          member_id
      end
    end
  end

  # Diff two %User{} / %Household{} structs into the params map the
  # respective changeset expects. We only include fields that the
  # changeset allows; the :profile field is always included when it
  # differs - both User and Household changesets cast :profile.
  defp changes_map(original, updated) do
    fields = cast_fields(original.__struct__)

    fields
    |> Enum.reduce(%{}, fn field, acc ->
      orig_val = Map.get(original, field)
      new_val = Map.get(updated, field)

      if orig_val == new_val do
        acc
      else
        Map.put(acc, field, new_val)
      end
    end)
  end

  # Fields each schema's changeset allows via cast/3 - kept in sync
  # with User.changeset / Household.changeset.
  defp cast_fields(User), do: ~w(password date_enrolled concurrency_limit profile)a
  defp cast_fields(Household), do: ~w(enabled_date disabled_date disabled_reason profile)a

  # Scope enforcement: the requesting user must be permitted to UPDATE every
  # tac in a write. The subscriber is the household's A-suffixed user id;
  # everyone else is :user. Household / subscriber-only GEVs (the ADDRESS &
  # MEMBER INFO / option-5 section: billing address, member add/suspend,
  # household temp password) list only [:subscriber] in their ProfileSchema
  # update scope, so a non-A member's packet touching one is rejected
  # wholesale. Member self-service GEVs (own name/DOB/gender/password) list
  # [:user], so they pass.
  defp write_authorized?(entries, %User{} = user) do
    scope = requester_scope(user)

    Enum.all?(entries, fn {tac, _val} ->
      allowed = update_scopes(tac)
      # A subscriber is also a :user for their own fields (e.g. their own
      # password, 0x014F, update [:user]), so :subscriber satisfies a :user
      # requirement in addition to :subscriber-only fields.
      scope in allowed or (scope == :subscriber and :user in allowed)
    end)
  end

  defp requester_scope(%User{id: id}) do
    case String.upcase(String.last(id || "") || "") do
      "A" -> :subscriber
      _ -> :user
    end
  end

  defp update_scopes(tac) do
    case ProfileSchema.get(tac) do
      %{security: %{update: scopes}} -> scopes
      # Unknown tac falls back to the schema default (subscriber/oms only).
      _ -> [:subscriber, :oms]
    end
  end

  def handle(%Fm0{payload: payload} = request, %Context{user: user} = context) do
    Logger.debug("[profile] request packet: #{inspect(request, base: :hex, limit: :infinity)}")

    <<
      0x13,
      action,
      which_user,
      other_user_id::binary-size(7),
      filler::binary-size(5),
      _count::16-big,
      rest::binary
    >> = payload

    entries = parse_request_values(rest)
    Logger.debug("#{inspect(entries, base: :hex, limit: :infinity)}")

    # Re-read the user so server-owned mutable fields (notably the change-
    # password try counter #340, which the client both drives and reads back)
    # are current for BOTH reads and writes - context.user is cached at logon
    # and would otherwise be stale. Fall back to the passed struct if the row
    # is not persisted (in-memory test users).
    user =
      case user && Repo.get(User, user.id) do
        nil -> user
        fresh -> Repo.preload(fresh, :household)
      end

    result =
      case action do
        0x03 ->
          # Retrieve: encode each requested TAC.
          {:reply,
           Enum.reduce(entries, <<>>, fn {tac, _val}, buf ->
             buf <> get_tac(tac, user, user.household)
           end)}

        0x04 ->
          # A change-password write carries the transient verify-old TAC
          # (0x015D) alongside the new password (0x014F). Verify the old
          # against the stored hash; on mismatch reject the WHOLE write
          # (change nothing) and return a short error status. The verify
          # TAC is never persisted. A plain write (no verify TAC) applies
          # as before - this is how enrollment sets the initial password.
          {verify_entries, real_entries} =
            Enum.split_with(entries, fn {tac, _} -> tac == @verify_old_pw_tac end)

          # A service change-password write is one carrying the verify-old TAC.
          password_change = verify_entries != []

          cond do
            password_change and password_locked_out?(user) ->
              Logger.info("Password change for #{user.id} rejected: too many prior tries")
              :locked_out

            password_change and not old_password_ok?(user, verify_entries) ->
              Logger.info("Password change for #{user.id} rejected: old password mismatch")
              bump_password_try_count(user)
              :verify_failed

            not write_authorized?(real_entries, user) ->
              Logger.info(
                "Profile update for #{user.id} rejected: subscriber-only write by non-subscriber"
              )

              :scope_denied

            true ->
              Logger.info("Profile update received for user #{user.id}")

              # A successful password change resets the try counter (#340) via
              # User.changeset, which clears "0154" whenever :password changes -
              # so no explicit reset entry is needed here.
              {user_changeset, household_changeset, member_patches} =
                build_changesets(real_entries, user, user.household)

              # New member rows get the household TEMPORARY password
              # (PRF_HOUSEHOLD_PASSWORD #275 / key "0113"), not the subscriber's
              # current password - which diverges once the subscriber changes
              # it. Falls back to user.password for pre-#275 households.
              member_initial_password =
                case user.household do
                  %{profile: %{"0113" => pw}} when is_binary(pw) -> pw
                  _ -> user.password
                end

              Repo.transaction(fn ->
                if household_changeset, do: Repo.update!(household_changeset)

                if user.household && map_size(member_patches) > 0 do
                  persist_members(member_patches, user.household, member_initial_password)
                end

                Repo.update!(user_changeset |> Ecto.Changeset.change(date_enrolled: Timex.today()))
              end)

              Prodigy.Server.SessionManager.broadcast_profile_updated(user.id)

              {:reply, payload}
          end
      end

    case result do
      :locked_out ->
        # Too many failed old-password tries. Same coarse error as a mismatch -
        # xxopprof conveys only success/error, so the client shows a single
        # "Incorrect password or too many tries." message either way.
        {:ok, context, DiaPacket.encode(Fm0.make_response(<<0x05>>, request))}

      :verify_failed ->
        # 1-byte non-'0' status: xxopprof reads this as an error return.
        {:ok, context, DiaPacket.encode(Fm0.make_response(<<0x05>>, request))}

      :scope_denied ->
        # Non-subscriber attempted a subscriber-only (household) write; reject
        # the whole packet the same way, changing nothing.
        {:ok, context, DiaPacket.encode(Fm0.make_response(<<0x05>>, request))}

      {:reply, values} ->
        response_payload = <<
          0x13,
          action,
          which_user,
          other_user_id::binary-size(7),
          filler::binary-size(5),
          0x0::16-big,
          values::binary
        >>

        {:ok, context, DiaPacket.encode(Fm0.make_response(response_payload, request))}
    end
  end

  # Verify a submitted old password against the user's stored credential,
  # tolerating legacy rows that were stored un-hashed (mirrors Logon).
  defp old_password_ok?(user, verify_entries) do
    {_tac, old} = List.last(verify_entries)

    hash =
      if String.starts_with?(user.password, "$pbkdf2-sha512$"),
        do: user.password,
        else: Pbkdf2.hash_pwd_salt(user.password)

    Pbkdf2.verify_pass(old, hash)
  end

  # -- server-authoritative change-password try counter (#340) ---------

  # The counter is stored as a 1-char ASCII decimal string ("0".."3") so the
  # reception client can retrieve #340 and compare it numerically (>= '3').
  # nil / empty / non-digit is treated as 0.
  defp password_try_count(%User{profile: profile}) when is_map(profile) do
    case profile do
      %{@try_count_key => <<d>>} when d in ?0..?9 -> d - ?0
      _ -> 0
    end
  end

  defp password_try_count(_), do: 0

  defp password_locked_out?(user), do: password_try_count(user) >= @max_password_change_trys

  # Persist an incremented try count after a rejected old-password verify.
  # Stored as a single decimal digit; the count never exceeds 3 (a locked-out
  # write is rejected before any increment), so one digit always suffices.
  defp bump_password_try_count(%User{} = user) do
    n = password_try_count(user) + 1
    profile = Map.put(user.profile || %{}, @try_count_key, Integer.to_string(n))
    user |> User.changeset(%{profile: profile}) |> Repo.update!()
  end

  # -- compat shims --------------------------------------------------

  @doc """
  Backwards-compatible facade kept so `Prodigy.Server.Service.Enrollment`
  can reuse the same parser while we migrate it onto ProfileDispatch too.
  Builds the User change-params map expected by User.changeset.
  """
  def get_user_changeset(entries) do
    # Apply via ProfileDispatch against a blank user then extract the
    # diff in the params-map form User.changeset wants.
    empty_user = %User{}
    %{user: staged} = ProfileDispatch.apply_entries(entries, empty_user, nil)
    changes_map(empty_user, staged)
  end

  @doc """
  Backwards-compatible facade - same idea as `get_user_changeset/1` but
  for households. Used by `Enrollment.ex`.
  """
  def get_household_changeset(entries) do
    empty_hh = %Household{}
    empty_user = %User{}
    %{household: staged} = ProfileDispatch.apply_entries(entries, empty_user, empty_hh)
    if is_nil(staged), do: %{}, else: changes_map(empty_hh, staged)
  end
end
