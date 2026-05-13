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

defmodule Prodigy.Core.Data.Service.ProfileDispatchTest do
  use ExUnit.Case, async: true

  alias Prodigy.Core.Data.Service.{Household, ProfileDispatch, User}

  # -- resolve_target/3 -------------------------------------------

  describe "resolve_target/3" do
    test "household TAC targets the household struct" do
      user = %User{id: "AAAA11A"}
      hh = %Household{id: "AAAA11"}
      assert {^hh, "0102"} = ProfileDispatch.resolve_target(0x0102, user, hh)
    end

    test "user TAC (no slot) targets the user struct" do
      user = %User{id: "AAAA11A"}
      hh = %Household{id: "AAAA11"}
      assert {^user, "015E"} = ProfileDispatch.resolve_target(0x015E, user, hh)
    end

    test "slot TAC targets the household" do
      # Slot data lives in the household's JSONB; the per-slot User
      # row is not consulted for these TACs.
      user = %User{id: "AAAA11A"}
      hh = %Household{id: "AAAA11"}
      # 0x011A = PRF_USER_ITEM_LAST_A (slot A last name)
      assert {^hh, "011A"} = ProfileDispatch.resolve_target(0x011A, user, hh)
    end

    test "unknown TAC returns {:error, :unknown_tac}" do
      user = %User{id: "AAAA11A"}
      hh = %Household{id: "AAAA11"}
      assert {:error, :unknown_tac} = ProfileDispatch.resolve_target(0xDEAD, user, hh)
    end
  end

  # -- get_value/3 -----------------------------------------------

  describe "get_value/3" do
    test "password reads from the User.password column" do
      user = %User{id: "AAAA11A", password: "$pbkdf2-sha512$..."}
      assert ProfileDispatch.get_value(0x014F, user, nil) == "$pbkdf2-sha512$..."
    end

    test "user id reads from User.id" do
      user = %User{id: "AAAA11A"}
      assert ProfileDispatch.get_value(0x014E, user, nil) == "AAAA11A"
    end

    test "household id reads from Household.id" do
      hh = %Household{id: "AAAA11"}
      assert ProfileDispatch.get_value(0x0111, %User{id: "AAAA11A"}, hh) == "AAAA11"
    end

    test "reads from JSONB when the key is present" do
      user = %User{
        id: "AAAA11A",
        profile: %{"015F" => "Ada", "015E" => "Lovelace"}
      }

      assert ProfileDispatch.get_value(0x015F, user, nil) == "Ada"
      assert ProfileDispatch.get_value(0x015E, user, nil) == "Lovelace"
    end

    test "returns \" \" when the JSONB key is missing" do
      # Missing JSONB keys return the same " " sentinel as unknown TACs.
      user = %User{id: "AAAA11A", profile: %{}}
      assert ProfileDispatch.get_value(0x015F, user, nil) == " "
    end

    test "returns \" \" for unknown TACs (legacy behavior)" do
      user = %User{id: "AAAA11A", profile: %{}}
      assert ProfileDispatch.get_value(0xDEAD, user, nil) == " "
    end

    test "binary TAC round-trips through base64" do
      # ProfileSchema marks 0x02FB (MadMaze save) as :binary - JSONB
      # holds a base64 string; get_value returns the decoded bytes.
      save = <<0, 1, 2, 3>>
      user = %User{id: "AAAA11A", profile: %{"02FB" => Base.encode64(save)}}
      assert ProfileDispatch.get_value(0x02FB, user, nil) == save
    end

    test "household slot read goes through the household's JSONB" do
      hh = %Household{id: "AAAA11", profile: %{"011A" => "Lovelace"}}
      user = %User{id: "AAAA11A"}
      assert ProfileDispatch.get_value(0x011A, user, hh) == "Lovelace"
    end

    test "household slot returns \" \" when the JSONB key is missing" do
      hh = %Household{id: "AAAA11", profile: %{}}
      user = %User{id: "AAAA11A"}
      assert ProfileDispatch.get_value(0x011A, user, hh) == " "
    end
  end

  # -- apply_entries/3 -------------------------------------------

  describe "apply_entries/3" do
    test "writes a user TAC to the User's JSONB" do
      user = %User{id: "AAAA11A", profile: %{}}
      hh = %Household{id: "AAAA11", profile: %{}}

      %{user: updated_user} =
        ProfileDispatch.apply_entries([{0x015F, "Ada"}], user, hh)

      assert updated_user.profile["015F"] == "Ada"
    end

    test "writes a household TAC to Household.profile" do
      user = %User{id: "AAAA11A"}
      hh = %Household{id: "AAAA11", profile: %{}}

      %{household: updated_hh} =
        ProfileDispatch.apply_entries([{0x0102, "123 Main"}], user, hh)

      assert updated_hh.profile["0102"] == "123 Main"
    end

    test "slot TAC writes land on the household's JSONB" do
      user = %User{id: "AAAA11A"}
      hh = %Household{id: "AAAA11", profile: %{}}

      %{household: updated_hh} =
        ProfileDispatch.apply_entries([{0x011A, "Lovelace"}], user, hh)

      assert updated_hh.profile["011A"] == "Lovelace"
    end

    test "date TACs encode as MMDDYY in JSONB" do
      user = %User{id: "AAAA11A", profile: %{}}

      %{user: updated_user} =
        ProfileDispatch.apply_entries([{0x0162, "030576"}], user, nil)

      assert updated_user.profile["0162"] == "030576"
    end

    test "password staging goes to User.password (caller hashes)" do
      user = %User{id: "AAAA11A"}

      %{user: updated_user} =
        ProfileDispatch.apply_entries([{0x014F, "newpass"}], user, nil)

      assert updated_user.password == "newpass"
      refute Map.has_key?(updated_user.profile || %{}, "014F")
    end

    test "unknown TACs are silently skipped" do
      user = %User{id: "AAAA11A", profile: %{"015F" => "Ada"}}

      %{user: updated_user} =
        ProfileDispatch.apply_entries([{0xDEAD, "garbage"}], user, nil)

      assert updated_user.profile == %{"015F" => "Ada"}
    end

    test "multiple entries accumulate across user and household" do
      user = %User{id: "AAAA11A", profile: %{}}
      hh = %Household{id: "AAAA11", profile: %{}}

      result =
        ProfileDispatch.apply_entries(
          [
            {0x015F, "Ada"},
            {0x015E, "Lovelace"},
            {0x0102, "123 Main"},
            {0x0104, "Springfield"}
          ],
          user,
          hh
        )

      assert result.user.profile["015F"] == "Ada"
      assert result.user.profile["015E"] == "Lovelace"
      assert result.household.profile["0102"] == "123 Main"
      assert result.household.profile["0104"] == "Springfield"
    end

    # Regression (2026-04-19): "remove yourself from the Member List"
    # sends TAC 0x02B0 (PRF_ML_INDICATOR) with value <<0x00>>. That
    # schema entry was mis-declared as :ascii, so the null byte flowed
    # straight into the JSONB profile map - and Postgres rejected the
    # row with `22P05 (untranslatable_character)`, crashing the TCS
    # session. The fix flips the schema entry to :binary, which causes
    # the write path to base64-encode it.
    test "PRF_ML_INDICATOR with <<0x00>> round-trips as base64, not raw NUL" do
      user = %User{id: "AAAA11A", profile: %{}}

      %{user: updated} =
        ProfileDispatch.apply_entries([{0x02B0, <<0x00>>}], user, nil)

      stored = updated.profile["02B0"]

      # Stored representation is base64 of a single NUL byte. Must NOT
      # contain a literal \u0000 - that's exactly what breaks jsonb.
      assert is_binary(stored)
      refute String.contains?(stored, <<0x00>>)
      assert stored == Base.encode64(<<0x00>>)

      # Round-trip: reading it back yields the original raw byte.
      reloaded = %User{user | profile: %{"02B0" => stored}}
      assert ProfileDispatch.get_value(0x02B0, reloaded, nil) == <<0x00>>
    end
  end
end
