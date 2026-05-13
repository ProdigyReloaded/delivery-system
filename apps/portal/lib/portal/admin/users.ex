# Copyright 2026, Phillip Heller
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

defmodule Prodigy.Portal.Admin.Users do
  @moduledoc """
  Queries + actions the admin "Users" tab calls into. Service users only
  (Prodigy 7-char IDs like AAAA11A) - portal users are self-service and
  don't need an admin surface yet.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ecto.Multi
  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, Session, User}
  alias Prodigy.Portal.Admin.Sessions
  alias Prodigy.Portal.Admin.UserForm
  alias Prodigy.Server.SessionManager

  @doc """
  All service users with household + portal_user preloaded, each wrapped
  in a map `%{user: %User{}, online?: boolean}`. Ordered by ID so the
  table is stable before the user picks a sort.
  """
  def list do
    users =
      from(u in User,
        preload: [:household, :portal_user],
        order_by: [asc: u.id]
      )
      |> Repo.all()

    online_ids = online_user_ids()

    Enum.map(users, fn user ->
      %{user: user, online?: MapSet.member?(online_ids, user.id)}
    end)
  end

  @doc """
  Fetch a single service user by id with household + portal_user preloaded,
  or nil.
  """
  def get(user_id) when is_binary(user_id) do
    User
    |> Repo.get(user_id)
    |> Repo.preload([:household, :portal_user])
  end

  @doc """
  Build the edit-form changeset. Backed by `Admin.UserForm`, an
  embedded-schema view model whose fields (first_name, middle_name,
  last_name, title, gender, birthdate, concurrency_limit) map to JSONB
  TACs on save - the service User schema no longer casts those columns.
  """
  def edit_changeset(%User{} = user, attrs \\ %{}) do
    user
    |> UserForm.from_user()
    |> UserForm.changeset(attrs)
  end

  @doc """
  Apply an admin edit. The form straddles both the user and the
  household; `UserForm.profile_patch/1` returns two TAC-keyed patches
  applied to each entity's `profile` JSONB. The name/title changes are
  also mirrored into the household's slot keys so anything that reads
  by slot TAC (Profile service, per-user-id lookups) sees them. All
  writes commit together or not at all.

  Broadcasts `:profile_updated` on success so the admin LiveView refreshes.
  """
  def update(%User{} = user, attrs) do
    form_cs = edit_changeset(user, attrs)

    if form_cs.valid? do
      %{user: user_patch, household: household_patch} = UserForm.profile_patch(form_cs)
      new_user_profile = UserForm.apply_patch(user.profile || %{}, user_patch)

      user_changeset =
        user
        |> change(%{
          profile: new_user_profile,
          concurrency_limit:
            get_field(form_cs, :concurrency_limit) || user.concurrency_limit
        })

      Multi.new()
      |> Multi.update(:user, user_changeset)
      |> Multi.run(:household, fn _repo, %{user: updated_user} ->
        sync_household(updated_user, user_patch, household_patch)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: updated_user}} ->
          SessionManager.broadcast_profile_updated(updated_user.id)
          {:ok, updated_user}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    else
      {:error, %{form_cs | action: :validate}}
    end
  end

  @doc """
  Reset a service user's password. Normalizes to the Prodigy client's
  on-wire contract (uppercase A-Z / digits, max 10 chars) before hashing,
  because the DOS RS client uppercases user input before transmitting
  it over TCS - a lowercase hash would never verify.

  Does not invalidate any in-flight TCS session - those stay authenticated
  until they disconnect.

  Returns `{:ok, %User{}}` on success, `{:error, :invalid_password}` if
  the input can't be coerced to the A-Z / 0-9, 2-10 char contract, or
  `{:error, %Ecto.Changeset{}}` if the changeset fails on save.
  """
  def reset_password(%User{} = user, new_password) when is_binary(new_password) do
    case validate_password(new_password) do
      {:ok, normalized} ->
        user
        |> User.changeset(%{password: normalized})
        |> Repo.update()

      :error ->
        {:error, :invalid_password}
    end
  end

  @doc """
  Generate an 8-character password using the same A-Z / 2-9 alphabet as
  pomsutil's `enroll` path, skipping visually-ambiguous characters (I, O,
  0, 1) so the admin can read it back over the phone without confusion.
  """
  def generate_password do
    alphabet = ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    len = length(alphabet)

    for _ <- 1..8, into: "", do: <<Enum.at(alphabet, :rand.uniform(len) - 1)>>
  end

  @doc """
  Soft-delete a service user by stamping `date_deleted` with today. If the
  user is currently online, their session is force-disconnected first so
  the deletion takes immediate effect (Logon.deleted/1 rejects logon when
  date_deleted is non-nil, but an already-open TCS session keeps running
  until the transport closes).

  Returns `{:ok, %User{}}` on success.
  """
  def soft_delete(%User{} = user) do
    _ = force_disconnect(user)

    result =
      user
      |> change(%{date_deleted: Date.utc_today()})
      |> Repo.update()

    with {:ok, updated} <- result do
      SessionManager.broadcast_profile_updated(updated.id)
      {:ok, updated}
    end
  end

  @doc "Clear `date_deleted`, restoring the user to a signed-in-able state."
  def undelete(%User{} = user) do
    result =
      user
      |> change(%{date_deleted: nil})
      |> Repo.update()

    with {:ok, updated} <- result do
      SessionManager.broadcast_profile_updated(updated.id)
      {:ok, updated}
    end
  end

  @doc """
  Force-disconnect the user's active session, if any. Shares the same
  teardown path as the Online tab's disconnect button: signals the Router
  process, which cascades through DIA -> TCS and runs Logoff.handle_abnormal
  so SessionManager closes the row and broadcasts :session_closed.

  Returns:
    * `:ok` - disconnected or no active session found
    * `{:error, {:remote_node, node}}` - session lives on another node
    * `{:error, reason}` - other failure
  """
  def force_disconnect(%User{id: user_id}) do
    case active_session_for(user_id) do
      nil -> :ok
      %Session{} = session -> Sessions.disconnect(session)
    end
  end

  defp active_session_for(user_id) do
    from(s in Session,
      where: s.user_id == ^user_id,
      where: is_nil(s.logoff_timestamp),
      order_by: [desc: s.logon_timestamp],
      limit: 1
    )
    |> Repo.one()
  end

  defp validate_password(pw) do
    normalized = String.upcase(pw)

    cond do
      not String.match?(normalized, ~r/^[A-Z0-9]+$/) -> :error
      # RS client refuses to transmit a 1-char password (won't even
      # initiate the TCS connection), so gate it here.
      String.length(normalized) < 2 -> :error
      String.length(normalized) > 10 -> :error
      true -> {:ok, normalized}
    end
  end

  # ------------------------------------------------------------------

  defp online_user_ids do
    from(s in Session,
      where: is_nil(s.logoff_timestamp),
      select: s.user_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # Apply the household-info patch from the admin form, plus - for the
  # slot-A user only - the name/title mirror under the household's
  # slot-A keys (0x011A..0x011D), which the TCS retrieve path still
  # reads. Slot-B..F name/title data lives on each member's own User
  # row (written by `update/2` via `new_user_profile`); the household
  # slot-B..F keys were dropped, so there's no mirror for those.
  # Combined into one Repo.update so the whole edit commits or rolls
  # back together.
  defp sync_household(
         %User{id: user_id, household_id: household_id},
         user_patch,
         household_patch
       ) do
    with {:ok, slot} <- slot_from_user_id(user_id),
         %Household{} = household <- Repo.get(Household, household_id) do
      slot_patch = if slot == "a", do: build_slot_a_patch(user_patch), else: %{}
      combined = Map.merge(household_patch, slot_patch)

      if map_size(combined) == 0 do
        {:ok, household}
      else
        new_profile = UserForm.apply_patch(household.profile || %{}, combined)

        household
        |> change(%{profile: new_profile})
        |> Repo.update()
      end
    else
      :error -> {:error, :bad_user_id_shape}
      nil -> {:error, :household_not_found}
    end
  end

  defp build_slot_a_patch(user_patch) do
    mapping = %{"015F" => :first, "0160" => :middle, "015E" => :last, "0161" => :title}
    slot_keys = Household.slot_keys("a")

    Enum.reduce(mapping, %{}, fn {user_key, field}, acc ->
      case Map.fetch(user_patch, user_key) do
        :error -> acc
        {:ok, val} -> Map.put(acc, Map.fetch!(slot_keys, field), val)
      end
    end)
  end

  defp slot_from_user_id(<<_::binary-size(6), letter::binary-size(1)>>)
       when letter in ~w(A B C D E F a b c d e f) do
    {:ok, String.downcase(letter)}
  end

  defp slot_from_user_id(_), do: :error
end
