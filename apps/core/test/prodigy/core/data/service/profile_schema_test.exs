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

defmodule Prodigy.Core.Data.Service.ProfileSchemaTest do
  use ExUnit.Case, async: true

  alias Prodigy.Core.Data.Service.ProfileSchema

  # -- get/1, known?/1, all/0 ------------------------------------

  describe "get/1" do
    test "returns a populated entry for a known TAC" do
      assert %{name: "PRF_USER_LAST_NAME", entity: :user, type: :ascii, length: 20} =
               ProfileSchema.get(0x015E)
    end

    test "carries full field shape on every entry" do
      entry = ProfileSchema.get(0x015E)

      for key <- [
            :name,
            :label,
            :entity,
            :slot,
            :type,
            :length,
            :source,
            :group,
            :group_label,
            :index,
            :security,
            :storage
          ] do
        assert Map.has_key?(entry, key),
               "expected entry for 0x015E to include :#{key}; got #{inspect(entry)}"
      end
    end

    test "returns nil for an unknown TAC" do
      assert ProfileSchema.get(0xBAD1) == nil
    end
  end

  describe "known?/1" do
    test "true for a registered TAC" do
      assert ProfileSchema.known?(0x0102)
    end

    test "false for an unregistered TAC" do
      refute ProfileSchema.known?(0xFFFE)
    end
  end

  describe "all/0" do
    test "returns a non-empty map" do
      fields = ProfileSchema.all()
      assert is_map(fields)
      assert map_size(fields) > 0
    end

    test "every value has :name/:label/:entity/:type/:length/:provisional" do
      for {tac, field} <- ProfileSchema.all() do
        assert is_binary(field.name), "TAC 0x#{Integer.to_string(tac, 16)} missing :name"
        assert is_binary(field.label), "TAC 0x#{Integer.to_string(tac, 16)} missing :label"
        assert field.entity in [:user, :household]
        assert field.type in [:ascii, :binary, :date_mmddyy]
        assert is_integer(field.length) and field.length > 0
        assert is_boolean(field.provisional)
      end
    end

    test "every :source is one of the allowed tags" do
      for {_tac, field} <- ProfileSchema.all() do
        assert field.source in [:tpf, :oms, :both]
      end
    end

    test "every :security carries retrieve + update scope lists" do
      for {_tac, field} <- ProfileSchema.all() do
        assert %{retrieve: r, update: u} = field.security
        assert Enum.all?(r, &(&1 in [:subscriber, :user, :oms]))
        assert Enum.all?(u, &(&1 in [:subscriber, :user, :oms]))
      end
    end

    test "slots, when set, are single uppercase letters A..F" do
      for {_tac, %{slot: slot}} <- ProfileSchema.all(), not is_nil(slot) do
        assert slot in ["A", "B", "C", "D", "E", "F"]
      end
    end
  end

  # -- by_entity/1, by_slot/1, by_group/1 -----------------------

  describe "by_entity/1" do
    test "filters to :household" do
      result = ProfileSchema.by_entity(:household)
      assert map_size(result) > 0
      for {_tac, %{entity: e}} <- result, do: assert(e == :household)
    end

    test "filters to :user" do
      result = ProfileSchema.by_entity(:user)
      assert map_size(result) > 0
      for {_tac, %{entity: e}} <- result, do: assert(e == :user)
    end

    test "household + user counts sum to total" do
      total = map_size(ProfileSchema.all())
      assert map_size(ProfileSchema.by_entity(:household)) +
               map_size(ProfileSchema.by_entity(:user)) == total
    end
  end

  describe "by_slot/1" do
    test "returns 6 entries per slot (last, first, middle, title, access_level, indicators)" do
      for slot <- ["A", "B", "C", "D", "E", "F"] do
        result = ProfileSchema.by_slot(slot)

        assert map_size(result) == 6,
               "expected 6 fields for slot #{slot}, got #{map_size(result)}"

        for {_tac, field} <- result, do: assert(field.slot == slot)
      end
    end

    test "returns empty for unknown slot" do
      assert ProfileSchema.by_slot("Z") == %{}
    end
  end

  describe "by_group/1" do
    test "personal_path returns 20 entries in index order" do
      result = ProfileSchema.by_group(:personal_path)
      assert length(result) == 20

      indices = Enum.map(result, fn {_tac, %{index: i}} -> i end)
      assert indices == Enum.to_list(0..19)
    end

    test "personal_path indexes map to the expected logical ordering" do
      # 1-12 at 0x023F-0x024A; 13-20 at 0x020A-0x0211 (non-contiguous).
      result = ProfileSchema.by_group(:personal_path)
      tacs_in_order = Enum.map(result, fn {tac, _field} -> tac end)

      assert Enum.take(tacs_in_order, 12) == Enum.to_list(0x023F..0x024A)
      assert Enum.drop(tacs_in_order, 12) == Enum.to_list(0x020A..0x0211)
    end

    test "personal_path entries are 13 chars per XXCGTSYS" do
      for {_tac, field} <- ProfileSchema.by_group(:personal_path) do
        assert field.length == 13
      end
    end

    test "credit_card_1 through credit_card_4 each have 3 fields in order" do
      for card <- 1..4 do
        result = ProfileSchema.by_group(String.to_atom("credit_card_#{card}"))
        assert length(result) == 3

        [{tac0, _}, {tac1, _}, {tac2, _}] = result
        base = 0x0167 + (card - 1) * 3
        assert {tac0, tac1, tac2} == {base, base + 1, base + 2}
      end
    end

    test "bank_v1_1 through bank_v1_3 each have 3 fields" do
      for bank <- 1..3 do
        result = ProfileSchema.by_group(String.to_atom("bank_v1_#{bank}"))
        assert length(result) == 3
      end
    end

    test "bank_v2_3 has 9 fields (skips the #733 'intentionally skipped' TAC)" do
      # Banks 1, 2, 4, 5 each have 10 fields; bank 3 has 9 due to the
      # XXCGTSYS-documented gap.
      for bank <- [1, 2, 4, 5] do
        assert length(ProfileSchema.by_group(String.to_atom("bank_v2_#{bank}"))) == 10
      end

      assert length(ProfileSchema.by_group(:bank_v2_3)) == 9
    end

    test "repeating-5 groups each have 5 fields" do
      for group <- [
            :direct_mktg_responses,
            :leisure_activities,
            :magazine_subscriptions,
            :personalization,
            :ingram_categories
          ] do
        assert length(ProfileSchema.by_group(group)) == 5
      end
    end
  end

  describe "coverage scale" do
    test "registry has at least 250 entries (the full XXCGTSYS pull)" do
      assert map_size(ProfileSchema.all()) >= 250
    end

    test "residence_address returns the 5 address fields in order" do
      result = ProfileSchema.by_group(:residence_address)
      tacs_in_order = Enum.map(result, fn {tac, _field} -> tac end)
      assert tacs_in_order == [0x0102, 0x0103, 0x0104, 0x0105, 0x0106]
    end

    test "user_slot_a returns all 6 slot A fields in order" do
      result = ProfileSchema.by_group(:user_slot_a)
      assert length(result) == 6
      tacs_in_order = Enum.map(result, fn {tac, _field} -> tac end)
      # last, first, middle, title, access_level, indicators
      assert tacs_in_order == [0x011A, 0x011B, 0x011C, 0x011D, 0x011F, 0x0120]
    end

    test "unknown group returns empty list" do
      assert ProfileSchema.by_group(:no_such_group) == []
    end
  end

  describe "tacs/0" do
    test "returns a sorted list of integers" do
      result = ProfileSchema.tacs()
      assert result == Enum.sort(result)
      assert Enum.all?(result, &is_integer/1)
    end
  end

  # -- provisional flag ------------------------------------------

  describe "provisional/0" do
    test "returns a non-empty map (many XXCGTSYS-only fields are inferred)" do
      result = ProfileSchema.provisional()
      assert map_size(result) > 0
    end

    test "every provisional entry has :provisional == true" do
      for {_tac, field} <- ProfileSchema.provisional() do
        assert field.provisional == true
      end
    end

    test "non-provisional fields exist too (not everything is inferred)" do
      all = ProfileSchema.all()
      provisional = ProfileSchema.provisional()
      assert map_size(all) > map_size(provisional)
    end
  end

  describe "non-provisional coverage" do
    test "password is not provisional" do
      refute ProfileSchema.get(0x014F).provisional
    end

    test "residence address fields are not provisional (PDF-authoritative)" do
      for tac <- [0x0102, 0x0103, 0x0104, 0x0105, 0x0106] do
        refute ProfileSchema.get(tac).provisional,
               "TAC 0x#{Integer.to_string(tac, 16)} should not be provisional"
      end
    end

    test "user name group is not provisional" do
      for tac <- [0x015E, 0x015F, 0x0160, 0x0161] do
        refute ProfileSchema.get(tac).provisional
      end
    end
  end

  # -- password special case -------------------------------------

  describe "password (0x014F)" do
    test "is flagged :password_column storage" do
      assert %{storage: :password_column} = ProfileSchema.get(0x014F)
    end

    test "has :user-only security scope (not subscriber or oms)" do
      assert %{security: %{retrieve: [:user], update: [:user]}} = ProfileSchema.get(0x014F)
    end

    test "is the only entry with :password_column storage" do
      password_entries =
        ProfileSchema.all()
        |> Enum.filter(fn {_tac, %{storage: s}} -> s == :password_column end)

      assert length(password_entries) == 1
      assert [{0x014F, _}] = password_entries
    end
  end

  # -- smoke test: registry covers every TAC Profile.ex dispatches --

  describe "coverage vs Prodigy.Server.Service.Profile" do
    # Keep in sync with the case blocks in
    # apps/server/lib/prodigy/server/service/profile.ex. If you add a
    # TAC to Profile.ex without registering it here, this test yells.
    @profile_ex_tacs [
      # Household - from get_value + get_household_changeset.
      0x0102,
      0x0103,
      0x0104,
      0x0105,
      0x0106,
      0x0107,
      0x010E,
      0x010F,
      0x0110,
      0x0111,
      0x0112,
      0x0113,
      0x0114,
      0x0115,
      0x0116,
      0x011A,
      0x011B,
      0x011C,
      0x011D,
      0x011F,
      0x0120,
      0x0123,
      0x0124,
      0x0125,
      0x0126,
      0x0128,
      0x0129,
      0x012C,
      0x012D,
      0x012E,
      0x012F,
      0x0131,
      0x0132,
      0x0135,
      0x0136,
      0x0137,
      0x0138,
      0x013A,
      0x013B,
      0x013E,
      0x013F,
      0x0140,
      0x0141,
      0x0143,
      0x0144,
      0x0147,
      0x0148,
      0x0149,
      0x014A,
      0x014C,
      0x014D,
      # User.
      0x014E,
      0x014F,
      0x0150,
      0x0152,
      0x0153,
      0x0154,
      0x0155,
      0x0156,
      0x0157,
      0x0159,
      0x015A,
      0x015B,
      0x015C,
      0x015E,
      0x015F,
      0x0160,
      0x0161,
      0x0162,
      0x020A,
      0x020B,
      0x020C,
      0x020D,
      0x020E,
      0x020F,
      0x0210,
      0x0211,
      0x023F,
      0x0240,
      0x0241,
      0x0242,
      0x0243,
      0x0244,
      0x0245,
      0x0246,
      0x0247,
      0x0248,
      0x0249,
      0x024A,
      0x02C2,
      0x02C4,
      0x02FB
    ]

    test "every TAC dispatched by Profile.ex has a registry entry" do
      missing = Enum.reject(@profile_ex_tacs, &ProfileSchema.known?/1)

      assert missing == [],
             "TACs in Profile.ex missing from ProfileSchema: " <>
               Enum.map_join(missing, ", ", &("0x" <> Integer.to_string(&1, 16)))
    end

    test "registry :entity matches Profile.ex dispatch target" do
      # Profile.ex's get_value/3 routes TACs 0x102-0x14D to the household
      # record and TACs 0x14E-0x2FB to the user record. The registry
      # should line up with that dispatch - TACs below 0x14E are
      # household-routed, TACs at/above are user-routed. The user slot
      # TACs (0x11A..0x14D range) are a special case called out below.
      for tac <- @profile_ex_tacs do
        entry = ProfileSchema.get(tac)

        cond do
          # User slot A..F TACs: schema declares :user + slot. The
          # dispatch resolver targets the household for these because
          # the slot data lives in the household's JSONB.
          not is_nil(entry.slot) ->
            assert entry.entity == :user
            assert entry.slot in ["A", "B", "C", "D", "E", "F"]

          tac < 0x014E ->
            assert entry.entity == :household,
                   "TAC 0x#{Integer.to_string(tac, 16)} should be :household"

          true ->
            assert entry.entity == :user,
                   "TAC 0x#{Integer.to_string(tac, 16)} should be :user"
        end
      end
    end
  end

  describe "slot_member_tac/1" do
    test "maps slot name/title TACs to {slot, user_own_tac}" do
      # Slot A
      assert {"A", 0x015E} = ProfileSchema.slot_member_tac(0x011A)
      assert {"A", 0x015F} = ProfileSchema.slot_member_tac(0x011B)
      assert {"A", 0x0160} = ProfileSchema.slot_member_tac(0x011C)
      assert {"A", 0x0161} = ProfileSchema.slot_member_tac(0x011D)
      # Slot B
      assert {"B", 0x015E} = ProfileSchema.slot_member_tac(0x0123)
      assert {"B", 0x015F} = ProfileSchema.slot_member_tac(0x0124)
      # Slot F
      assert {"F", 0x015E} = ProfileSchema.slot_member_tac(0x0147)
      assert {"F", 0x0161} = ProfileSchema.slot_member_tac(0x014A)
    end

    test "returns nil for access_level / indicators slot TACs (no user-own equivalent)" do
      assert ProfileSchema.slot_member_tac(0x011F) == nil
      assert ProfileSchema.slot_member_tac(0x0120) == nil
      assert ProfileSchema.slot_member_tac(0x0128) == nil
      assert ProfileSchema.slot_member_tac(0x0129) == nil
    end

    test "returns nil for non-slot TACs" do
      assert ProfileSchema.slot_member_tac(0x015E) == nil
      assert ProfileSchema.slot_member_tac(0x0102) == nil
      assert ProfileSchema.slot_member_tac(0xDEAD) == nil
    end
  end
end
