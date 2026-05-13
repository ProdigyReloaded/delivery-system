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

defmodule Prodigy.Core.Data.Service.ProfileBackfill do
  @moduledoc """
  Encodes the Service.User and Service.Household named Ecto columns
  into the JSONB shape the `profile` column now holds. Used by the
  one-time backfill migration that populated existing rows when the
  JSONB column was introduced; tests exercise the encoding round-trip.

  Consumers:

  * `priv/repo/migrations/20260421000100_backfill_profile_jsonb.exs`
    iterates existing rows and calls `user/1` / `household/1`.
  * Tests in `apps/core/test` exercise the encoding round-trip.

  The mapping below pairs each known Ecto column with its TAC hex
  key. TACs in `ProfileSchema` that have no named column backing them
  (credit cards, banks, RS8 additions, most provisional entries)
  simply don't appear here and are skipped during backfill - their
  JSONB slot stays absent until something actually writes to it.

  JSONB encoding per `ProfileSchema.type/1`:

  * `:ascii`        -> raw string, as stored.
  * `:binary`       -> base64-encoded string.
  * `:date_mmddyy`  -> `"MMDDYY"` string formatted from the Ecto `:date`.

  JSONB keys are uppercase four-digit hex TAC strings (`"0102"`,
  `"014F"`, `"023F"`) for readability in pg output.
  """

  alias Prodigy.Core.Data.Service.{Household, ProfileSchema, User}

  # -- column <-> TAC maps -----------------------------------------

  # Named columns on Service.User today that back a ProfileSchema TAC.
  # Password (0x014F) is deliberately absent - it stays a hashed
  # :password_column and is never copied into JSONB. Primary keys
  # (user.id == 0x014E) are also absent: they're identity, not profile.
  @user_columns %{
    gender: 0x0157,
    date_enrolled: 0x0159,
    date_deleted: 0x015A,
    last_name: 0x015E,
    first_name: 0x015F,
    middle_name: 0x0160,
    title: 0x0161,
    birthdate: 0x0162,
    prf_path_jumpword_1: 0x023F,
    prf_path_jumpword_2: 0x0240,
    prf_path_jumpword_3: 0x0241,
    prf_path_jumpword_4: 0x0242,
    prf_path_jumpword_5: 0x0243,
    prf_path_jumpword_6: 0x0244,
    prf_path_jumpword_7: 0x0245,
    prf_path_jumpword_8: 0x0246,
    prf_path_jumpword_9: 0x0247,
    prf_path_jumpword_10: 0x0248,
    prf_path_jumpword_11: 0x0249,
    prf_path_jumpword_12: 0x024A,
    prf_path_jumpword_13: 0x020A,
    prf_path_jumpword_14: 0x020B,
    prf_path_jumpword_15: 0x020C,
    prf_path_jumpword_16: 0x020D,
    prf_path_jumpword_17: 0x020E,
    prf_path_jumpword_18: 0x020F,
    prf_path_jumpword_19: 0x0210,
    prf_path_jumpword_20: 0x0211,
    prf_last_logon_date: 0x02C2,
    prf_last_logon_time: 0x02C4,
    prf_madmaze_save: 0x02FB
  }

  # Household columns that back TACs. The slot user_a..user_f fields
  # duplicate per-slot profile data; the backfill captures them under
  # the household's own JSONB so the shadow is complete. The runtime
  # dispatch layer (ProfileDispatch) prefers the per-slot User row's
  # profile over these slot fields when reading.
  @household_columns %{
    address_1: 0x0102,
    address_2: 0x0103,
    city: 0x0104,
    state: 0x0105,
    zipcode: 0x0106,
    telephone: 0x0107,
    enabled_date: 0x010E,
    disabled_date: 0x010F,
    disabled_reason: 0x0110,
    subscriber_suffix: 0x0112,
    household_password: 0x0113,
    # 0x0114 (income range), 0x0115 (suffix in use), 0x0116 (account
    # status) have no backing columns today - the schema module is
    # marked `??` for those. Skipped.
    user_a_last: 0x011A,
    user_a_first: 0x011B,
    user_a_middle: 0x011C,
    user_a_title: 0x011D,
    user_a_access_level: 0x011F,
    user_a_indicators: 0x0120,
    user_b_last: 0x0123,
    user_b_first: 0x0124,
    user_b_middle: 0x0125,
    user_b_title: 0x0126,
    user_b_access_level: 0x0128,
    user_b_indicators: 0x0129,
    user_c_last: 0x012C,
    user_c_first: 0x012D,
    user_c_middle: 0x012E,
    user_c_title: 0x012F,
    user_c_access_level: 0x0131,
    user_c_indicators: 0x0132,
    user_d_last: 0x0135,
    user_d_first: 0x0136,
    user_d_middle: 0x0137,
    user_d_title: 0x0138,
    user_d_access_level: 0x013A,
    user_d_indicators: 0x013B,
    user_e_last: 0x013E,
    user_e_first: 0x013F,
    user_e_middle: 0x0140,
    user_e_title: 0x0141,
    user_e_access_level: 0x0143,
    user_e_indicators: 0x0144,
    user_f_last: 0x0147,
    user_f_first: 0x0148,
    user_f_middle: 0x0149,
    user_f_title: 0x014A,
    user_f_access_level: 0x014C,
    user_f_indicators: 0x014D
  }

  # -- public API ------------------------------------------------

  @doc """
  Build the JSONB profile map for a User record by reading each known
  named column and encoding it per the ProfileSchema type. Returns the
  map ready for assignment to `user.profile`. Nil columns are omitted.
  """
  @spec user(User.t()) :: %{String.t() => term()}
  def user(%User{} = u), do: build(u, @user_columns)

  @doc """
  Build the JSONB profile map for a Household record by reading each
  known named column and encoding it per the ProfileSchema type.
  """
  @spec household(Household.t()) :: %{String.t() => term()}
  def household(%Household{} = h), do: build(h, @household_columns)

  @doc "Turn an integer TAC into the uppercase 4-digit hex key used in JSONB."
  @spec tac_key(non_neg_integer()) :: String.t()
  def tac_key(tac) when is_integer(tac) do
    String.pad_leading(Integer.to_string(tac, 16), 4, "0") |> String.upcase()
  end

  @doc """
  Encode a column value to its JSONB representation per the given
  ProfileSchema `:type`.
  """
  def encode(nil, _type), do: nil
  def encode(value, :ascii) when is_binary(value), do: value
  def encode(value, :binary) when is_binary(value), do: Base.encode64(value)

  def encode(%Date{} = d, :date_mmddyy) do
    two = fn n -> n |> Integer.to_string() |> String.pad_leading(2, "0") end
    two.(d.month) <> two.(d.day) <> two.(rem(d.year, 100))
  end

  # Some TACs of :date_mmddyy type map to a column that's stored as a
  # string already (e.g., prf_last_logon_date). Pass through.
  def encode(value, :date_mmddyy) when is_binary(value), do: value

  def encode(_, _), do: nil

  # -- implementation --------------------------------------------

  defp build(record, column_map) do
    for {column, tac} <- column_map,
        meta = ProfileSchema.get(tac),
        not is_nil(meta),
        value = Map.get(record, column),
        not is_nil(value),
        encoded = encode(value, meta.type),
        not is_nil(encoded),
        into: %{} do
      {tac_key(tac), encoded}
    end
  end

  @doc """
  Column maps exposed for introspection / tests. Keys are the Ecto
  column atoms; values are TAC integers.
  """
  def user_columns, do: @user_columns
  def household_columns, do: @household_columns
end
