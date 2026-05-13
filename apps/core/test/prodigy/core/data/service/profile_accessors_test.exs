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

defmodule Prodigy.Core.Data.Service.ProfileAccessorsTest do
  @moduledoc """
  JSONB-backed accessors on User and Household.
  """
  use ExUnit.Case, async: true

  alias Prodigy.Core.Data.Service.{Household, User}

  describe "User accessors" do
    test "return JSONB values for each known key" do
      user = %User{
        profile: %{
          "015F" => "Ada",
          "0160" => "King",
          "015E" => "Lovelace",
          "0161" => "Countess",
          "0157" => "F",
          "0162" => "121045"
        }
      }

      assert User.first_name(user) == "Ada"
      assert User.middle_name(user) == "King"
      assert User.last_name(user) == "Lovelace"
      assert User.title(user) == "Countess"
      assert User.gender(user) == "F"
      # "121045" = MM=12, DD=10, YY=45; yy >= 39 -> 1945-12-10
      assert User.birthdate(user) == ~D[1945-12-10]
    end

    test "return nil when JSONB key is absent" do
      user = %User{profile: %{}}
      assert User.first_name(user) == nil
      assert User.last_name(user) == nil
      assert User.gender(user) == nil
      assert User.birthdate(user) == nil
    end

    test "return nil when JSONB value is an empty string" do
      user = %User{profile: %{"015F" => ""}}
      assert User.first_name(user) == nil
    end

    test "full_name joins first and last, skips absent halves" do
      assert User.full_name(%User{profile: %{"015F" => "Ada", "015E" => "Lovelace"}}) ==
               "Ada Lovelace"

      assert User.full_name(%User{profile: %{"015F" => "Ada"}}) == "Ada"
      assert User.full_name(%User{profile: %{}}) == ""
    end

    test "birthdate pivots two-digit year matching Profile.to2digitdate" do
      # yy >= 39 -> 1900+yy (dates of birth live in the 1900s)
      pre39 = %User{profile: %{"0162" => "010176"}}
      assert User.birthdate(pre39) == ~D[1976-01-01]

      # yy < 39 -> 2000+yy (future-dated DoBs acceptable)
      post39 = %User{profile: %{"0162" => "010105"}}
      assert User.birthdate(post39) == ~D[2005-01-01]
    end

    test "last_logon_date / last_logon_time read JSONB keys 02C2 / 02C4" do
      user = %User{profile: %{"02C2" => "041826", "02C4" => "14:30"}}
      assert User.last_logon_date(user) == "041826"
      assert User.last_logon_time(user) == "14:30"
    end
  end

  describe "Household accessors" do
    test "slot helpers resolve per-slot TAC keys" do
      hh = %Household{
        profile: %{
          "011A" => "Lovelace",
          "011B" => "Ada",
          "011C" => "K",
          "011D" => "Countess",
          "0123" => "Babbage"
        }
      }

      assert Household.slot_first(hh, "a") == "Ada"
      assert Household.slot_middle(hh, "a") == "K"
      assert Household.slot_last(hh, "a") == "Lovelace"
      assert Household.slot_title(hh, "a") == "Countess"

      assert Household.slot_last(hh, "b") == "Babbage"
      assert Household.slot_first(hh, "b") == nil
    end

    test "address/city helpers" do
      hh = %Household{
        profile: %{
          "0102" => "123 Main St",
          "0104" => "Brooklyn",
          "0106" => "11201"
        }
      }

      assert Household.address_1(hh) == "123 Main St"
      assert Household.city(hh) == "Brooklyn"
      assert Household.zipcode(hh) == "11201"
      assert Household.telephone(hh) == nil
    end

    test "slot_keys returns the four TACs for a given slot letter" do
      assert Household.slot_keys("a") == %{
               last: "011A",
               first: "011B",
               middle: "011C",
               title: "011D"
             }

      assert Household.slot_keys("F") == Household.slot_keys("f")
    end
  end
end
