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

defmodule Prodigy.Server.MemberList.SchemaTest do
  use ExUnit.Case, async: true

  alias Prodigy.Core.Objects.Ccdam
  alias Prodigy.Server.MemberList.Schema

  defp h(hex), do: Base.decode16!(hex, case: :mixed)

  @msplstat_ref Base.decode16!(
                  "4d53504c53544154442020010c950220010161830202414c2f0a414c4142414d41414b2f09414c41534b41415a2f0a4152495a4f4e4141522f0b41524b414e53415343412f0d43414c49464f524e4941434f2f0b434f4c4f5241444f43542f0e434f4e4e4543544943555444432f1057415348494e47544f4e20444344452f0b44454c4157415245464c2f0a464c4f5249444147412f0a47454f5247494148492f0948415741494949442f08494441484f494c2f0b494c4c494e4f4953494e2f0a494e4449414e4149412f07494f57414b532f094b414e5341534b592f0b4b454e5455434b594c412f0c4c4f55495349414e414d452f084d41494e454d442f0b4d4152594c414e444d412f104d4153534143485553455454534d492f0b4d4943484947414e4d4e2f0c4d494e4e45534f54414d532f0e4d495353495353495050494d4f2f0b4d4953534f5552494d542f0a4d4f4e54414e414e452f0b4e45425241534b414e562f094e45564144414e482f104e45572048414d5053484952454e4a2f0d4e4557204a45525345594e4d2f0d4e4557204d455849434f4e592f0b4e455720594f524b4e432f114e4f525448204341524f4c494e414e442f0f4e4f5254482044414b4f54414f482f074f48494f4f4b2f0b4f4b4c41484f4d414f522f094f5245474f4e50412f0f50454e4e53594c56414e494152492f0f52484f44452049534c414e4453432f11534f555448204341524f4c494e4153442f0f534f5554482044414b4f5441544e2f0c54454e4e455353454554582f08544558415355542f075554414856542f0a5645524d4f4e5456412f0b56495247494e494157412f0d57415348494e47544f4e57562f10574553542056495247494e494157492f0c574953434f4e53494e57592f0a57594f4d494e47",
                  case: :mixed
                )

  describe "states/0" do
    test "returns 51 entries (50 states + DC)" do
      assert length(Schema.states()) == 51
    end

    test "every code is exactly 2 ASCII chars; every name is a non-empty ASCII string" do
      for {code, name} <- Schema.states() do
        assert byte_size(code) == 2
        assert String.match?(code, ~r/^[A-Z]{2}$/)
        assert byte_size(name) > 0
        assert String.match?(name, ~r/^[A-Z ]+$/)
      end
    end

    test "preserves the historical Prodigy order (alphabetical by name, with DC slotted by code)" do
      # Sanity-check the head + the DC/DE quirk; the full ordering is
      # validated implicitly by the byte-exact MSPLSTAT.D01 fixture.
      assert Enum.take(Schema.states(), 4) ==
               [{"AL", "ALABAMA"}, {"AK", "ALASKA"}, {"AZ", "ARIZONA"}, {"AR", "ARKANSAS"}]

      dc_pos = Enum.find_index(Schema.states(), &(elem(&1, 0) == "DC"))
      de_pos = Enum.find_index(Schema.states(), &(elem(&1, 0) == "DE"))
      assert dc_pos + 1 == de_pos, "DC must immediately precede DE (sorted by code, not name)"
    end
  end

  describe "msplstat_object/1" do
    test "matches the golden fixture byte-for-byte (version: 1)" do
      assert Schema.msplstat_object(version: 1) == @msplstat_ref
    end
  end

  describe "schema_3b / schema_3l" do
    test "schema_3b validates and has the four search keys we depend on" do
      s = Schema.schema_3b()
      assert Ccdam.Schema.validate!(s) == s
      assert Enum.map(s.search_keys, & &1.key_id) == [1, 2, 3, 4]

      assert Enum.map(s.search_keys, & &1.name) == [
               "name_all_states",
               "name_city_state",
               "states",
               "cities_in_state"
             ]
    end

    test "schema_3l validates and is a single-key db_type=1" do
      s = Schema.schema_3l()
      assert Ccdam.Schema.validate!(s) == s
      assert s.db_type == 1
      assert length(s.search_keys) == 1
      [k] = s.search_keys
      assert k.fields == [{"user_id", 1}]
    end

    test "encode_dad/3 for the 3L schema (single-segment, all-fields) matches the fixture" do
      # Captured with total_records=5, db_type=1 + segments=[all fields].
      expected = h("010100000005010a05000705000205001205000005001405000f05000105000505000005000001050100010101")
      assert Ccdam.encode_dad(Schema.schema_3l(), 5) == expected
    end

    test "dad_object/3 for the 3L schema matches the fixture" do
      expected = h("334c303030303030442020010c430020010161310002010100000005010a05000705000205001205000005001405000f05000105000505000005000001050100010101")
      assert Ccdam.dad_object(Schema.schema_3l(), 5, version: 1) == expected
    end
  end

  describe "Y-object (3L per-member TDO page)" do
    test "build_y_object/3 matches the golden fixture for a known member" do
      member = %{
        "user_id" => "AAAA11A",
        "state" => "TX",
        "city" => "AUSTIN",
        "unknown1" => "",
        "last_name" => "SMITH",
        "first_name" => "JANE",
        "middle" => "Q",
        "title" => "Mr.",
        "unknown2" => "",
        "unknown3" => ""
      }

      expected =
        h(
          "334c303030303031592020010c5d00200101614b000203000141414141313141545841555354494e202020202020202020202020534d4954482020202020202020202020202020204a414e452020202020202020202020514d722e2020"
        )

      assert Schema.build_y_object(member, "000001", version: 1) == expected
    end
  end

  describe "TDO references" do
    test "tdo_ref/1 zero-pads to 6 digits + Y" do
      assert Schema.tdo_ref(1) == "000001Y"
      assert Schema.tdo_ref(42) == "000042Y"
      assert Schema.tdo_ref(123_456) == "123456Y"
    end

    test "y_object_extra_data/1 prefixes the TDO ref with the pages byte 0x00" do
      member = %{"_tdo_ref" => "000007Y"}
      assert Schema.y_object_extra_data(member) == <<0>> <> "000007Y"
    end
  end
end
