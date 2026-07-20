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

defmodule Prodigy.Server.MemberList.GeneratorTest do
  @moduledoc """
  Tests the pure `build_blobs/2` path - the full object set produced from
  a fixed in-memory member list, no DB required. The end-to-end run that
  goes through `Store.reconcile_prefix` lives in
  `Prodigy.Portal.MemberListGeneratorE2ETest` (because it needs
  `Portal.DataCase`).
  """
  use ExUnit.Case, async: true

  alias Prodigy.Core.Objects.Codec
  alias Prodigy.Server.MemberList.{Generator, Schema}

  # Three opted-in members already carrying their `_tdo_ref` (mimics
  # what Generator.run/1 assigns before calling build_blobs/2).
  defp sample_members do
    [
      %{
        "user_id" => "AAAA11A",
        "state" => "TX",
        "city" => "AUSTIN",
        "unknown" => "",
        "last_name" => "SMITH",
        "first_name" => "JANE",
        "middle" => "Q",
        "title" => "Mr.",
        "unknown1" => "",
        "unknown2" => "",
        "unknown3" => "",
        "_tdo_ref" => Schema.tdo_ref(1)
      },
      %{
        "user_id" => "BBBB22A",
        "state" => "TX",
        "city" => "HOUSTON",
        "unknown" => "",
        "last_name" => "JONES",
        "first_name" => "BOB",
        "middle" => "",
        "title" => "Mr.",
        "unknown1" => "",
        "unknown2" => "",
        "unknown3" => "",
        "_tdo_ref" => Schema.tdo_ref(2)
      },
      %{
        "user_id" => "CCCC33A",
        "state" => "CA",
        "city" => "LOS ANGELES",
        "unknown" => "",
        "last_name" => "DOE",
        "first_name" => "ALICE",
        "middle" => "",
        "title" => "Mrs.",
        "unknown1" => "",
        "unknown2" => "",
        "unknown3" => "",
        "_tdo_ref" => Schema.tdo_ref(3)
      }
    ]
  end

  defp parse!(blob) do
    {:ok, parsed} = Codec.parse(blob)
    parsed
  end

  defp by_name_prefix(blobs, prefix) do
    Enum.filter(blobs, fn b -> String.starts_with?(parse!(b).header.name, prefix) end)
  end

  describe "build_blobs/2 — structure" do
    test "every blob parses; every header is candidacy 1, version we passed" do
      blobs = Generator.build_blobs(sample_members(), 7)
      assert length(blobs) > 0

      for b <- blobs do
        h = parse!(b).header
        assert h.candidacy == 1
        assert h.version == 7
        assert h.set_size == 1
        assert h.type == 0x0C
      end
    end

    test "produces the 3B DAD, sequence sets for keys 1..4, leaf IDOs, and the 3L DAD + Y-objects + S1" do
      blobs = Generator.build_blobs(sample_members(), 1)

      names = Enum.map(blobs, &parse!(&1).header.name)

      assert "3B000000D  " in names, "3B DAD object"
      assert "3L000000D  " in names, "3L DAD object"
      assert "MSPLSTATD  " in names, "MSPLSTAT.D01"

      # one sequence set per 3B key
      for k <- 1..4 do
        assert "3B000011S  " in names, "3B sequence set for key #{k}"
        assert Enum.any?(blobs, fn b ->
                 p = parse!(b).header
                 p.name == "3B000011S  " and p.sequence == k
               end), "3B sequence set with sequence=#{k}"
      end

      # one 3L sequence set on key 1
      assert Enum.any?(blobs, fn b ->
               p = parse!(b).header
               p.name == "3L000011S  " and p.sequence == 1
             end)

      # one Y-object per member
      for i <- 1..3 do
        expected = "3L" <> String.pad_leading(Integer.to_string(i), 6, "0") <> "Y  "
        assert expected in names, "expected #{expected} (the #{i}-th member's Y-object)"
      end
    end

    test "Y-object name matches the 6-digit prefix of the IDO record's TDO ref" do
      blobs = Generator.build_blobs(sample_members(), 1)
      members = sample_members()

      for m <- members do
        ref6 = binary_part(m["_tdo_ref"], 0, 6)
        y_name = "3L" <> ref6 <> "Y  "
        assert y_name in Enum.map(blobs, &parse!(&1).header.name)
      end
    end

    test "MSPLSTAT.D01 round-trips: header readable, body decodes to the state-name table" do
      [msplstat] = blobs = Generator.build_blobs(sample_members(), 1) |> by_name_prefix("MSPLSTAT")
      _ = blobs
      assert parse!(msplstat).header.name == "MSPLSTATD  "
      assert msplstat == Schema.msplstat_object(version: 1)
    end

    test "blob set is empty of any non-namespace names (only 3B/3L/MSPLSTAT*)" do
      blobs = Generator.build_blobs(sample_members(), 1)
      names = Enum.map(blobs, &parse!(&1).header.name)

      bad = Enum.reject(names, &(String.starts_with?(&1, "3B") or String.starts_with?(&1, "3L") or String.starts_with?(&1, "MSPLSTAT")))
      assert bad == []
    end

    test "empty member set still produces DAD + (empty) seq sets + MSPLSTAT — never crashes" do
      blobs = Generator.build_blobs([], 1)
      names = Enum.map(blobs, &parse!(&1).header.name)
      assert "3B000000D  " in names
      assert "3L000000D  " in names
      assert "MSPLSTATD  " in names
    end
  end

  describe "build_blobs/2 — content correctness" do
    test "3L Y-object's body matches Schema.build_y_object/3 byte-for-byte for each member" do
      blobs = Generator.build_blobs(sample_members(), 1)
      members = sample_members()

      for m <- members do
        ref6 = binary_part(m["_tdo_ref"], 0, 6)
        expected = Schema.build_y_object(m, ref6, version: 1)
        actual = Enum.find(blobs, &(parse!(&1).header.name == "3L" <> ref6 <> "Y  "))
        assert actual == expected
      end
    end
  end
end
