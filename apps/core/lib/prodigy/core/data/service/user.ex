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

defmodule Prodigy.Core.Data.Service.User do
  use Ecto.Schema
  import Ecto.Changeset


  @moduledoc """
  Schema specific to individual users and related change functions
  """

  @primary_key {:id, :string, []}
  schema "user" do
    belongs_to(:household, Prodigy.Core.Data.Service.Household, type: :string)
    # Optional link to the portal account that owns this service user.
    # One portal user may own many service users (head of household + family
    # member accounts AAAA11A / AAAA11B / ...). Nullable on the service side
    # because legacy users created by pomsutil predate portal accounts.
    belongs_to(:portal_user, Prodigy.Core.Data.Portal.User, type: :id)
    has_one(:data_collection_policy, Prodigy.Core.Data.Service.DataCollectionPolicy)
    has_many(:sessions, Prodigy.Core.Data.Service.Session)

    field(:password, :string)
    field(:date_enrolled, :date)
    field(:date_deleted, :date)
    field(:concurrency_limit, :integer, default: 1)

    # JSONB profile store - the sole store for name, title, gender,
    # birthdate, jumpword paths, last-logon stamps, and every other
    # TAC-addressable profile field. Keys are uppercase 4-digit hex
    # TACs ("015E", "02C2", etc.).
    field(:profile, :map, default: %{})
  end

  def changeset(user, params \\ %{}) do
    # Castable fields are housekeeping (password, date_enrolled,
    # concurrency_limit) plus the JSONB `:profile` map. Everything
    # else - names, title, gender, birthdate, jumpwords - lives
    # inside that map via TAC keys.
    user
    |> cast(params, [:password, :date_enrolled, :concurrency_limit, :profile])
    |> put_password_hash()
  end

  # -- JSONB-backed profile accessors -----------------------------
  #
  # Each accessor pulls one TAC key out of `user.profile` and returns
  # nil when the key is absent or empty.

  @doc "First name (TAC 0x015F)."
  def first_name(%__MODULE__{} = u), do: profile_string(u, "015F")

  @doc "Middle name (TAC 0x0160)."
  def middle_name(%__MODULE__{} = u), do: profile_string(u, "0160")

  @doc "Last name (TAC 0x015E)."
  def last_name(%__MODULE__{} = u), do: profile_string(u, "015E")

  @doc "Title (TAC 0x0161)."
  def title(%__MODULE__{} = u), do: profile_string(u, "0161")

  @doc "Gender (TAC 0x0157)."
  def gender(%__MODULE__{} = u), do: profile_string(u, "0157")

  @doc "Birthdate as a %Date{}; reads MMDDYY from TAC 0x0162."
  def birthdate(%__MODULE__{} = u) do
    case Map.get(u.profile || %{}, "0162") do
      mmddyy when is_binary(mmddyy) -> decode_mmddyy(mmddyy)
      _ -> nil
    end
  end

  @doc """
  Last-logon stamp kept as two TAC-addressable strings: date (`02C2`,
  MMDDYY) and time (`02C4`, HHMMSS).
  """
  def last_logon_date(%__MODULE__{} = u), do: profile_string(u, "02C2")
  def last_logon_time(%__MODULE__{} = u), do: profile_string(u, "02C4")

  @doc """
  `true` iff the user has opted in to the Member List directory.
  Source: `PRF_ML_INDICATOR` (TAC 0x02B0), a 1-byte `:binary` flag
  stored base64-encoded in JSONB (so the `<<0>>` "opted out" value
  survives the JSONB-as-text round-trip). Listed when the decoded
  byte is non-zero; nil/missing/undecodable is treated as not listed.
  """
  def in_member_list?(%__MODULE__{profile: profile}) do
    case profile && Map.get(profile, "02B0") do
      v when is_binary(v) and v != "" ->
        case Base.decode64(v) do
          {:ok, <<byte, _::binary>>} -> byte != 0
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  The stamp `PRF_ML_DATE` (TAC 0x02AF) carries - the date the indicator
  was last flipped. Format on the wire is 8-char `MMDDYYYY` (the DOS
  client's `SYS_DATE` includes a hard-coded `19xx` century, so a 2026
  flip lands as `"05131926"`). Returns the raw string or `nil`.
  """
  def member_list_date(%__MODULE__{} = u), do: profile_string(u, "02AF")

  @doc """
  Canonical "First Last" display string, skipping either half when
  absent. Used anywhere a user's name is shown - admin table, message
  attribution, logs.
  """
  def full_name(%__MODULE__{} = u) do
    [first_name(u), last_name(u)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
  end

  defp profile_string(%__MODULE__{profile: profile}, key) do
    case profile && Map.get(profile, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp decode_mmddyy(<<m::binary-size(2), d::binary-size(2), y::binary-size(2)>>) do
    with {mm, ""} <- Integer.parse(m),
         {dd, ""} <- Integer.parse(d),
         {yy, ""} <- Integer.parse(y) do
      # Mirror the two-digit-year pivot in Profile.to2digitdate/1 so
      # pre-1939 dates of birth don't roll into the 2060s.
      full_year = if yy >= 39, do: 1900 + yy, else: 2000 + yy

      case Date.new(full_year, mm, dd) do
        {:ok, date} -> date
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp decode_mmddyy(_), do: nil

  # Hashes the password if the changeset introduced a password change and the
  # value isn't already a pbkdf2 digest (so re-saving an existing User doesn't
  # re-hash a stored hash).
  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: pw}} = changeset) do
    if String.starts_with?(pw, "$pbkdf2-sha512$") do
      changeset
    else
      put_change(changeset, :password, Pbkdf2.hash_pwd_salt(pw))
    end
  end

  defp put_password_hash(changeset), do: changeset
end
