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

defmodule Prodigy.Portal.Admin.UserFormTest do
  @moduledoc """
  Direct unit tests for the admin Users-tab view model. `Admin.UsersTest`
  covers the DB-backed save path; this file exercises the form's public
  API in isolation - layout shape, `from_user/1` seeding, changeset
  validation, and `profile_patch/1` entity split - with plain structs.
  """
  use ExUnit.Case, async: true

  alias Prodigy.Core.Data.Service.{Household, User}
  alias Prodigy.Portal.Admin.UserForm

  describe "layout/0" do
    test "returns three tabs (personal info, household info, personal path)" do
      ids = UserForm.layout() |> Enum.map(& &1.id)
      assert ids == [:info, :household, :path]
    end

    test "each tab has at least one group with at least one field" do
      for tab <- UserForm.layout() do
        assert is_binary(tab.tab)
        assert [_ | _] = tab.groups

        for group <- tab.groups do
          assert [_ | _] = group.fields
        end
      end
    end

    test "every field spec carries label + type + routing info" do
      for tab <- UserForm.layout(),
          group <- tab.groups,
          spec <- group.fields do
        assert is_binary(spec.label)
        assert spec.type in [:text, :date, :number, :select, :checkbox, :readonly, :name_row]

        case spec.type do
          :readonly ->
            # Readonly rows render a value pulled from the user/
            # household struct - no form field, no entity/tac.
            assert spec.source in [:user, :household]
            assert is_function(spec.value_fn, 1)

          :name_row ->
            # Composite row - carries its own subfields, no single
            # :field atom of its own.
            assert spec.entity in [:user, :household]
            assert is_list(spec.subfields) and spec.subfields != []
            for sf <- spec.subfields, do: assert(is_atom(sf.field))

          _ ->
            assert is_atom(spec.field)
            assert spec.entity in [:user, :household]
        end
      end
    end

    test "personal path group uses columns: 2 for the 20 jumpwords" do
      path_tab = Enum.find(UserForm.layout(), &(&1.id == :path))
      [group] = path_tab.groups
      assert group.columns == 2
      assert length(group.fields) == 20
    end
  end

  describe "from_user/1" do
    test "seeds every editable field from JSONB accessors" do
      user = %User{
        id: "AAAA11A",
        concurrency_limit: 2,
        profile: %{
          "015F" => "Ada",
          "0160" => "K",
          "015E" => "Lovelace",
          "0161" => "Countess",
          "0157" => "F",
          "0162" => "121045",
          "023F" => "NEWS"
        },
        household: %Household{
          id: "AAAA11",
          profile: %{
            "0102" => "123 Main",
            "0104" => "Brooklyn",
            "0106" => "11201",
            "0107" => "5551234567"
          }
        }
      }

      form = UserForm.from_user(user)

      assert form.first_name == "Ada"
      assert form.middle_name == "K"
      assert form.last_name == "Lovelace"
      assert form.title == "Countess"
      assert form.gender == "F"
      assert form.birthdate == ~D[1945-12-10]
      assert form.concurrency_limit == 2
      assert form.address_1 == "123 Main"
      assert form.city == "Brooklyn"
      assert form.zipcode == "11201"
      assert form.telephone == "5551234567"
      assert form.path_1 == "NEWS"
    end

    test "gracefully handles a user without a preloaded household" do
      user = %User{id: "AAAA11A", concurrency_limit: 1, profile: %{}}
      form = UserForm.from_user(user)

      assert form.first_name == nil
      assert form.address_1 == nil
      assert form.telephone == nil
    end
  end

  describe "changeset/2" do
    test "accepts valid input across all three tabs" do
      form = UserForm.from_user(blank_user())

      cs =
        UserForm.changeset(form, %{
          "first_name" => "Alice",
          "address_1" => "1 Loop",
          "path_1" => "NEWS",
          "concurrency_limit" => "1"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :first_name) == "Alice"
      assert Ecto.Changeset.get_change(cs, :address_1) == "1 Loop"
      assert Ecto.Changeset.get_change(cs, :path_1) == "NEWS"
    end

    test "requires concurrency_limit" do
      form = UserForm.from_user(%User{id: "AAAA11A", profile: %{}, household: %Household{}})
      cs = UserForm.changeset(form, %{"concurrency_limit" => ""})
      refute cs.valid?
    end

    test "rejects concurrency_limit < 0" do
      form = UserForm.from_user(blank_user())
      cs = UserForm.changeset(form, %{"concurrency_limit" => "-2"})
      refute cs.valid?
    end

    test "per-TAC max length is enforced from ProfileSchema metadata" do
      form = UserForm.from_user(blank_user())

      # last_name TAC 0x015E has length 20.
      too_long = String.duplicate("x", 21)
      cs = UserForm.changeset(form, %{"last_name" => too_long, "concurrency_limit" => "1"})
      refute cs.valid?
      assert {"should be at most %{count} character(s)", _} = cs.errors[:last_name]

      # Personal Path is 13 chars.
      cs2 =
        UserForm.changeset(form, %{
          "path_1" => String.duplicate("X", 14),
          "concurrency_limit" => "1"
        })

      refute cs2.valid?
    end
  end

  describe "profile_patch/1" do
    test "splits changes into :user and :household patches by entity" do
      form = UserForm.from_user(blank_user())

      cs =
        UserForm.changeset(form, %{
          "first_name" => "Ada",
          "gender" => "F",
          "address_1" => "1 Loop",
          "city" => "Cupertino",
          "concurrency_limit" => "1"
        })

      %{user: user_patch, household: household_patch} = UserForm.profile_patch(cs)

      assert user_patch["015F"] == "Ada"
      assert user_patch["0157"] == "F"
      refute Map.has_key?(user_patch, "0102")

      assert household_patch["0102"] == "1 Loop"
      assert household_patch["0104"] == "Cupertino"
      refute Map.has_key?(household_patch, "015F")
    end

    test "cleared strings land as :__delete__ so apply_patch can remove the JSONB key" do
      # Start with the field pre-populated so the changeset sees nil as a change.
      user = %User{
        id: "AAAA11A",
        concurrency_limit: 1,
        profile: %{"015F" => "Ada"},
        household: %Household{id: "AAAA11", profile: %{}}
      }

      form = UserForm.from_user(user)

      cs = UserForm.changeset(form, %{"first_name" => "", "concurrency_limit" => "1"})
      %{user: patch} = UserForm.profile_patch(cs)
      assert patch["015F"] == :__delete__
    end

    test "date fields encode as MMDDYY strings in the user patch" do
      form = UserForm.from_user(blank_user())

      cs =
        UserForm.changeset(form, %{"birthdate" => "1985-03-14", "concurrency_limit" => "1"})

      %{user: patch} = UserForm.profile_patch(cs)
      assert patch["0162"] == "031485"
    end

    test "concurrency_limit is NOT part of either profile patch (not TAC-backed)" do
      form = UserForm.from_user(blank_user())
      cs = UserForm.changeset(form, %{"concurrency_limit" => "5"})
      %{user: u, household: h} = UserForm.profile_patch(cs)
      assert u == %{}
      assert h == %{}
    end
  end

  describe "apply_patch/2" do
    test "overlays values and drops keys marked :__delete__" do
      original = %{"015F" => "Ada", "015E" => "Lovelace", "0157" => "F"}

      patched =
        UserForm.apply_patch(original, %{"015F" => "Alicia", "015E" => :__delete__})

      assert patched == %{"015F" => "Alicia", "0157" => "F"}
    end

    test "leaves the original map untouched when the patch is empty" do
      original = %{"015F" => "Ada"}
      assert UserForm.apply_patch(original, %{}) == original
    end
  end

  describe "format_* read-only helpers" do
    test "format_enrolled distinguishes never-enrolled from enrolled-with-date" do
      assert UserForm.format_enrolled(%User{date_enrolled: nil}) =~ "No"
      assert UserForm.format_enrolled(%User{date_enrolled: ~D[2026-04-18]}) =~ "2026-04-18"
    end

    test "format_last_logon: Never when both keys absent" do
      assert UserForm.format_last_logon(%User{profile: %{}}) == "Never"
    end

    test "format_last_logon: date-only when time is missing" do
      assert UserForm.format_last_logon(%User{profile: %{"02C2" => "04/18/2026"}}) ==
               "04/18/2026"
    end

    test "format_last_logon: combines date + time when both present" do
      assert UserForm.format_last_logon(%User{
               profile: %{"02C2" => "04/18/2026", "02C4" => "14.30"}
             }) == "04/18/2026 14.30"
    end

    test "format_enabled shows ISO date or an em-dash" do
      assert UserForm.format_enabled(%Household{enabled_date: nil}) == "-"
      assert UserForm.format_enabled(%Household{enabled_date: ~D[2026-04-18]}) == "2026-04-18"
    end

    test "format_member_list_date returns '-' when never set" do
      assert UserForm.format_member_list_date(blank_user()) == "-"
    end

    test "format_member_list_date renders the stored MMDDYYYY as MM/DD/YY" do
      user = %{blank_user() | profile: %{"02AF" => "05131926"}}
      assert UserForm.format_member_list_date(user) == "05/13/26"
    end
  end

  describe "Member List opt-in" do
    test "from_user/1 reads in_member_list from PRF_ML_INDICATOR" do
      listed = %{blank_user() | profile: %{"02B0" => Base.encode64(<<1>>)}}
      unlisted = %{blank_user() | profile: %{"02B0" => Base.encode64(<<0>>)}}
      absent = blank_user()

      assert UserForm.from_user(listed).in_member_list == true
      assert UserForm.from_user(unlisted).in_member_list == false
      assert UserForm.from_user(absent).in_member_list == false
    end

    test "flipping the checkbox emits 02B0 + 02AF in the user patch" do
      cs = UserForm.changeset(UserForm.from_user(blank_user()), %{"in_member_list" => "true"})
      assert cs.valid?

      patch = UserForm.profile_patch(cs)
      assert patch.user["02B0"] == Base.encode64(<<1>>)

      # 02AF is stamped to today in the DOS client's 19YY format.
      today = Date.utc_today()
      mm = today.month |> Integer.to_string() |> String.pad_leading(2, "0")
      dd = today.day |> Integer.to_string() |> String.pad_leading(2, "0")
      yy = rem(today.year, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
      assert patch.user["02AF"] == "#{mm}#{dd}19#{yy}"
    end

    test "opt-out writes <<0>> indicator (mirrors MSPLDEL1's MOVE 0x00)" do
      listed_user = %{blank_user() | profile: %{"02B0" => Base.encode64(<<1>>)}}

      cs =
        UserForm.changeset(UserForm.from_user(listed_user), %{"in_member_list" => "false"})

      assert cs.valid?
      patch = UserForm.profile_patch(cs)
      assert patch.user["02B0"] == Base.encode64(<<0>>)
      assert is_binary(patch.user["02AF"])
    end

    test "leaving the checkbox alone does NOT emit 02B0 or 02AF" do
      # No `in_member_list` key in the submitted params - simulates the
      # admin opening the modal, editing nothing in that group, saving.
      cs = UserForm.changeset(UserForm.from_user(blank_user()), %{"first_name" => "Ada"})
      patch = UserForm.profile_patch(cs)

      refute Map.has_key?(patch.user, "02B0")
      refute Map.has_key?(patch.user, "02AF")
    end

    test "submitting the same value as already loaded is also a no-op" do
      listed = %{blank_user() | profile: %{"02B0" => Base.encode64(<<1>>)}}

      cs = UserForm.changeset(UserForm.from_user(listed), %{"in_member_list" => "true"})
      patch = UserForm.profile_patch(cs)

      refute Map.has_key?(patch.user, "02B0")
      refute Map.has_key?(patch.user, "02AF")
    end
  end

  # Helpers ------------------------------------------------------------

  defp blank_user do
    %User{
      id: "AAAA11A",
      concurrency_limit: 1,
      profile: %{},
      household: %Household{id: "AAAA11", profile: %{}}
    }
  end
end
