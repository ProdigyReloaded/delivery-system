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

defmodule Prodigy.Core.Objects.CcdamTest do
  use ExUnit.Case, async: true

  alias Prodigy.Core.Objects.Ccdam
  alias Prodigy.Core.Objects.Ccdam.{Field, Schema, SearchKey}

  # All hex fixtures here are captured golden output of the on-wire CCDAM
  # format; the encoder must produce byte-identical output for the same input.
  defp h(hex), do: Base.decode16!(hex, case: :mixed)

  describe "Field.format/2 (Fixed/Varchar/Integer value formatting)" do
    test "Fixed pads with spaces; truncates to length" do
      assert Field.format(Ccdam.fixed("x", 5), "AB") == h("4142202020")
      assert Field.format(Ccdam.fixed("x", 5), "TOO LONG STRING") == h("544f4f204c")
    end

    test "Fixed length=1 with an integer value emits a single byte" do
      assert Field.format(Ccdam.fixed("x", 1), 0x42) == <<0x42>>
    end

    test "Fixed length=0 emits zero bytes regardless of value" do
      assert Field.format(Ccdam.fixed("x", 0), "anything") == <<>>
    end

    test "Varchar1 prepends a 1-byte length" do
      assert Field.format(Ccdam.varchar1("x"), "AB") == h("024142")
    end

    test "Integer emits 2 bytes big-endian" do
      assert Field.format(Ccdam.integer("x"), 0x1234) == h("1234")
    end
  end

  describe "Field.descriptor/1 (field-to-bytes descriptor)" do
    test "Fixed -> 05, length-as-16-bit-big-endian" do
      assert Field.descriptor(Ccdam.fixed("x", 5)) == h("050005")
    end

    test "Varchar1 -> 01, 00 00" do
      assert Field.descriptor(Ccdam.varchar1("x")) == h("010000")
    end

    test "Integer -> 04, 00 00" do
      assert Field.descriptor(Ccdam.integer("x")) == h("040000")
    end
  end

  describe "Schema + DAD" do
    setup do
      schema = %Schema{
        db_handle: "3T",
        db_type: 0,
        db_driver: 1,
        fields: [Ccdam.fixed("last", 10), Ccdam.fixed("first", 10), Ccdam.fixed("state", 2)],
        search_keys: [
          %SearchKey{key_id: 1, name: "by_name", fields: [{"last", 1}, {"first", 1}]},
          %SearchKey{key_id: 2, name: "by_state_last", fields: [{"state", 1}, {"last", 1}]}
        ]
      }

      {:ok, schema: schema}
    end

    test "field_index/1 is 1-based", %{schema: s} do
      assert Schema.field_index(s) == %{"last" => 1, "first" => 2, "state" => 3}
    end

    test "num_width / page_num_width derive from handle length", %{schema: s} do
      assert Schema.num_width(s) == 6
      assert Schema.page_num_width(s) == 5
    end

    test "encode_dad/3 matches the golden fixture byte-for-byte", %{schema: s} do
      expected = h("0001000000050305000a05000a0500020207010002010102010702000203010101")
      assert Ccdam.encode_dad(s, 5) == expected
    end

    test "dad_object/3 emits the full Prodigy object (3T000000.D01)", %{schema: s} do
      expected =
        h(
          "3354303030303030442020010c3700200101612500020001000000050305000a05000a0500020207010002010102010702000203010101"
        )

      assert Ccdam.dad_object(s, 5, version: 1) == expected
    end

    test "validate! catches unknown field refs / duplicate keys / oversize handle", %{
      schema: s
    } do
      assert_raise ArgumentError, ~r/unknown field/, fn ->
        Schema.validate!(%{
          s
          | search_keys: [%SearchKey{key_id: 9, name: "bad", fields: [{"nope", 1}]}]
        })
      end

      assert_raise ArgumentError, ~r/duplicate search key ids/, fn ->
        Schema.validate!(%{
          s
          | search_keys: [
              %SearchKey{key_id: 1, name: "a", fields: [{"last", 1}]},
              %SearchKey{key_id: 1, name: "b", fields: [{"first", 1}]}
            ]
        })
      end

      assert_raise ArgumentError, ~r/db_handle .* too long/, fn ->
        Schema.validate!(%{s | db_handle: "TOOLONG"})
      end
    end
  end

  describe "build_index/4 — byte-exact against the golden fixtures" do
    @records [
      %{"last" => "JONES", "first" => "BOB", "state" => "NY"},
      %{"last" => "SMITH", "first" => "JANE", "state" => "CA"},
      %{"last" => "SMITH", "first" => "JOHN", "state" => "CA"},
      %{"last" => "DOE", "first" => "ALICE", "state" => "TX"},
      %{"last" => "DOE", "first" => "ZOE", "state" => "TX"}
    ]

    setup do
      schema = %Schema{
        db_handle: "3T",
        db_type: 0,
        db_driver: 1,
        fields: [Ccdam.fixed("last", 10), Ccdam.fixed("first", 10), Ccdam.fixed("state", 2)],
        search_keys: [
          %SearchKey{key_id: 1, name: "by_name", fields: [{"last", 1}, {"first", 1}]}
        ]
      }

      {:ok, schema: schema}
    end

    test "flat tree (5 records, rpi=10): 1 leaf + sequence set", %{schema: s} do
      # Expected order: leaf '3T000012S' first, then seq set '3T000011S'.
      expected_leaf =
        h(
          "3354303030303132532020010c85002001016173000210020005303030303030303030303030170014444f4520202020202020414c49434520202020200d0a0a5a4f45202020202020201700144a4f4e45532020202020424f4220202020202020170014534d49544820202020204a414e452020202020200c0b094f484e20202020202002"
        )

      expected_ss =
        h(
          "3354303030303131532020010c3e00200101612c00021300000000053030303031323030303031320214534d49544820202020204a4f484e202020202020"
        )

      blobs = Ccdam.build_index(s, 1, @records, records_per_ido: 10, version: 1)
      assert blobs == [expected_leaf, expected_ss]
    end

    test "tiered tree (rpi=2, kpi=2): 3 leaves + 2 intermediate pages + sequence set", %{
      schema: s
    } do
      # Expected order: 3 leaves (tier 3), 2 intermediate pages
      # (tier 2), 1 sequence set (tier 1).
      expected =
        [
          # leaf 1, tier 3: [DOE/ALICE, DOE/ZOE]
          "3354303030303133532020010c4b002001016139000210020002303030303030303030303233170014444f4520202020202020414c49434520202020200d0a0a5a4f452020202020202002",
          # leaf 2, tier 3: [JONES/BOB, SMITH/JANE]
          "3354303030303233532020010c550020010161430002100200023030303031333030303033331700144a4f4e45532020202020424f4220202020202020170014534d49544820202020204a414e4520202020202002",
          # leaf 3, tier 3: [SMITH/JOHN]
          "3354303030303333532020010c3e00200101612c000210020001303030303233303030303030170014534d49544820202020204a4f484e20202020202002",
          # intermediate page 1, tier 2: refs to leaves 1-2
          "3354303030303132532020010c4700200101613500020700000000000014444f45202020202020205a4f452020202020202014534d49544820202020204a414e45202020202020",
          # intermediate page 2, tier 2: ref to leaf 3
          "3354303030303232532020010c3200200101612000020700000000020014534d49544820202020204a4f484e202020202020",
          # sequence set, tier 1
          "3354303030303131532020010c5300200101614100021300000000053030303031323030303032320214534d49544820202020204a414e4520202020202014534d49544820202020204a4f484e202020202020"
        ]
        |> Enum.map(&h/1)

      blobs =
        Ccdam.build_index(s, 1, @records,
          records_per_ido: 2,
          keys_per_index_page: 2,
          version: 1
        )

      assert blobs == expected
    end

    test "zero records: emits a single entry-less sequence set, no leaf IDOs", %{
      schema: _
    } do
      # Same schema-shape the state-picker key uses in practice: 3B,
      # single Fixed(state, 2) field, key 3. Captured from
      # CcdamDatabase.build_index with records=[].
      tiny =
        %Schema{
          db_handle: "3B",
          db_type: 0,
          db_driver: 1,
          fields: [Ccdam.fixed("state", 2)],
          search_keys: [%SearchKey{key_id: 3, name: "states", fields: [{"state", 1}]}]
        }

      expected =
        h(
          "3342303030303131532020030c29002001016117000213000000000030303030303030303030303002"
        )

      assert Ccdam.build_index(tiny, 3, [], records_per_ido: 100, version: 1) == [expected]
    end

    test ":write callback receives each blob in order, function returns :ok", %{schema: s} do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      writer = fn blob -> Agent.update(agent, &[blob | &1]) end

      result =
        Ccdam.build_index(s, 1, @records, records_per_ido: 10, version: 1, write: writer)

      assert result == :ok
      assert Agent.get(agent, &Enum.reverse(&1)) ==
               Ccdam.build_index(s, 1, @records, records_per_ido: 10, version: 1)

      Agent.stop(agent)
    end
  end
end
