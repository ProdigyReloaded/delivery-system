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

defmodule Prodigy.Server.MemberList.SourceTest do
  use ExUnit.Case, async: true

  alias Prodigy.Core.Data.Service.{Household, User}
  alias Prodigy.Server.MemberList.Source

  # Build an opted-in user struct (with household preloaded). Override
  # individual fields via the opts; pass `indicator: <<0>>` to opt out,
  # `disabled_date: ~D[...]` to disable the household, etc.
  defp listed_user(opts \\ []) do
    profile = Map.merge(default_user_profile(), Keyword.get(opts, :profile, %{}))
    hh_profile = Map.merge(default_household_profile(), Keyword.get(opts, :household_profile, %{}))

    %User{
      id: Keyword.get(opts, :id, "AAAA11A"),
      household_id: "AAAA11",
      date_enrolled: Keyword.get(opts, :date_enrolled, ~D[2026-01-01]),
      date_deleted: Keyword.get(opts, :date_deleted),
      profile: profile,
      household: %Household{
        id: "AAAA11",
        disabled_date: Keyword.get(opts, :disabled_date),
        profile: hh_profile
      }
    }
  end

  # Default user profile: opted in (indicator <<1>>), with Smith/Jane/Q/Mr.
  defp default_user_profile do
    %{
      "02B0" => Base.encode64(<<1>>),
      "015E" => "SMITH",
      "015F" => "JANE",
      "0160" => "Q",
      "0161" => "Mr."
    }
  end

  defp default_household_profile do
    %{
      "0104" => "AUSTIN",
      "0105" => "TX"
    }
  end

  describe "to_record/1 — eligibility" do
    test "an opted-in, enrolled, addressed user yields one record" do
      assert [r] = Source.to_record(listed_user())

      assert r == %{
               "user_id" => "AAAA11A",
               "state" => "TX",
               "city" => "AUSTIN",
               "unknown" => "",
               "last_name" => "SMITH",
               "first_name" => "JANE",
               "middle" => "Q",
               "title" => "Mr."
             }
    end

    test "PRF_ML_INDICATOR unset / nil → excluded" do
      assert [] = Source.to_record(listed_user(profile: %{"02B0" => nil}))
    end

    test "PRF_ML_INDICATOR decodes to a zero byte → excluded (the 'remove me' state)" do
      assert [] = Source.to_record(listed_user(profile: %{"02B0" => Base.encode64(<<0>>)}))
    end

    test "PRF_ML_INDICATOR with any non-zero byte → included" do
      for byte <- [1, 2, 0xFF] do
        assert [_] = Source.to_record(listed_user(profile: %{"02B0" => Base.encode64(<<byte>>)}))
      end
    end

    test "PRF_ML_INDICATOR that doesn't decode as base64 → defensively excluded" do
      assert [] = Source.to_record(listed_user(profile: %{"02B0" => "not-base64!@#$"}))
    end

    test "no household → excluded" do
      u = %User{listed_user() | household: nil}
      assert [] = Source.to_record(u)
    end

    test "household disabled → excluded" do
      assert [] = Source.to_record(listed_user(disabled_date: ~D[2026-04-01]))
    end

    test "missing last name → excluded (nothing to index under)" do
      assert [] = Source.to_record(listed_user(profile: %{"015E" => ""}))
      assert [] = Source.to_record(listed_user(profile: %{"015E" => nil}))
    end

    test "missing state → excluded (no state/city indexes possible)" do
      assert [] = Source.to_record(listed_user(household_profile: %{"0105" => ""}))
      assert [] = Source.to_record(listed_user(household_profile: %{"0105" => nil}))
    end

    test "missing city is fine; city field is blank in the record" do
      assert [r] = Source.to_record(listed_user(household_profile: %{"0104" => ""}))
      assert r["city"] == ""
    end

    test "blank optional name fields (first/middle/title) pass through as ''" do
      assert [r] =
               Source.to_record(
                 listed_user(profile: %{"015F" => nil, "0160" => nil, "0161" => nil})
               )

      assert r["first_name"] == ""
      assert r["middle"] == ""
      assert r["title"] == ""
    end

    test "stray surrounding whitespace in profile fields is trimmed" do
      assert [r] =
               Source.to_record(
                 listed_user(
                   profile: %{"015E" => "  SMITH  ", "015F" => " JANE "},
                   household_profile: %{"0104" => "  AUSTIN ", "0105" => " TX "}
                 )
               )

      assert r["last_name"] == "SMITH"
      assert r["first_name"] == "JANE"
      assert r["city"] == "AUSTIN"
      assert r["state"] == "TX"
    end
  end
end
