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

defmodule Prodigy.Core.Data.Service.Household do
  use Ecto.Schema
  import Ecto.Changeset


  @moduledoc """
  Schema specific to Households and related change functions
  """

  @primary_key {:id, :string, []}
  schema "household" do
    has_many(:users, Prodigy.Core.Data.Service.User)

    field(:enabled_date, :date)
    field(:disabled_date, :date)
    field(:disabled_reason, :string)

    # JSONB profile store - the sole store for address/city/state/zip/
    # phone, household_password, subscriber_suffix, and the per-slot
    # user_<a-f>_<field> data. Keys are uppercase 4-digit hex TACs
    # ("0102", "011A", etc.).
    field(:profile, :map, default: %{})
  end

  def changeset(household, params \\ %{}) do
    # Castable fields are housekeeping (enabled_date, disabled_*)
    # plus the JSONB `:profile` map. Addresses, phone, and all
    # slot_A..F data live inside that map via TAC keys.
    cast(household, params, [:enabled_date, :disabled_date, :disabled_reason, :profile])
  end

  # -- JSONB-backed profile accessors -----------------------------
  #
  # Each accessor pulls one TAC key (resolved via `slot_keys/1` for
  # per-slot fields) out of `household.profile` and returns nil when
  # the key is absent or empty.

  @slot_tacs %{
    "a" => %{last: "011A", first: "011B", middle: "011C", title: "011D"},
    "b" => %{last: "0123", first: "0124", middle: "0125", title: "0126"},
    "c" => %{last: "012C", first: "012D", middle: "012E", title: "012F"},
    "d" => %{last: "0135", first: "0136", middle: "0137", title: "0138"},
    "e" => %{last: "013E", first: "013F", middle: "0140", title: "0141"},
    "f" => %{last: "0147", first: "0148", middle: "0149", title: "014A"}
  }

  @doc "Four slot-field TAC keys for a letter `a..f`."
  def slot_keys(slot) when is_binary(slot) and byte_size(slot) == 1 do
    Map.fetch!(@slot_tacs, String.downcase(slot))
  end

  def slot_first(%__MODULE__{} = h, slot), do: profile_string(h, slot_keys(slot).first)
  def slot_middle(%__MODULE__{} = h, slot), do: profile_string(h, slot_keys(slot).middle)
  def slot_last(%__MODULE__{} = h, slot), do: profile_string(h, slot_keys(slot).last)
  def slot_title(%__MODULE__{} = h, slot), do: profile_string(h, slot_keys(slot).title)

  def address_1(%__MODULE__{} = h), do: profile_string(h, "0102")
  def address_2(%__MODULE__{} = h), do: profile_string(h, "0103")
  def city(%__MODULE__{} = h), do: profile_string(h, "0104")
  def state(%__MODULE__{} = h), do: profile_string(h, "0105")
  def zipcode(%__MODULE__{} = h), do: profile_string(h, "0106")
  def telephone(%__MODULE__{} = h), do: profile_string(h, "0107")

  defp profile_string(%__MODULE__{profile: profile}, key) do
    case profile && Map.get(profile, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
