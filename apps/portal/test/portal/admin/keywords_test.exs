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

defmodule Prodigy.Portal.Admin.KeywordsTest do
  use Prodigy.Portal.DataCase, async: true

  alias Prodigy.Core.Data.Service.Keyword, as: ObjectKeyword
  alias Prodigy.Portal.Admin.Keywords

  defp seed!(keyword, object_name) do
    type = 0x04
    sequence = 0
    %ObjectKeyword{}
    |> ObjectKeyword.changeset(%{
      keyword: keyword,
      object_name: String.pad_trailing(object_name, 11, " "),
      object_sequence: sequence,
      object_type: type
    })
    |> Repo.insert!()
  end

  describe "list/0" do
    test "returns keywords in alphabetical order" do
      seed!("WEATHER", "WM0")
      seed!("NEWS", "NH0")
      seed!("DIRECTORY", "ICG")

      assert Enum.map(Keywords.list(), & &1.keyword) == ["DIRECTORY", "NEWS", "WEATHER"]
    end

    test "empty table yields an empty list" do
      assert Keywords.list() == []
    end
  end

  describe "delete/1" do
    test "removes the row and returns the deleted struct" do
      seed!("BYE", "OBJ")
      assert {:ok, %ObjectKeyword{keyword: "BYE"}} = Keywords.delete("BYE")
      assert Keywords.list() == []
    end

    test "returns :not_found for a missing keyword" do
      assert Keywords.delete("GHOST") == :not_found
    end

    test "broadcasts :keywords_deleted after a successful delete" do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, Keywords.topic())
      seed!("B", "OBJ")
      assert {:ok, _} = Keywords.delete("B")
      assert_receive :keywords_deleted, 500
    end
  end

  describe "topic/0" do
    test "exposes a stable string" do
      assert Keywords.topic() == "service:keywords"
    end
  end

  describe "rebuild_index/0" do
    alias Prodigy.Core.Data.Service.Object
    alias Prodigy.Core.Objects.KeywordIndex

    # Seed a batch of keywords, run rebuild_index, and inspect the
    # resulting primary + secondary rows. Each test re-seeds since
    # DataCase sandboxes the DB per test.
    defp seed_keywords!(specs) do
      for {kw, name} <- specs do
        seed!(kw, name)
      end
    end

    test "refuses when the keyword table is empty" do
      assert Keywords.rebuild_index() == {:error, :no_keywords}
    end

    test "writes one primary + N secondaries, each landing as :inserted" do
      # 16 keywords -> 2 chunks of 14 + 2 = 2 secondaries, since
      # keywords_per_secondary = 14.
      specs =
        for letter <- ~w(A B C D E F G H I J K L M N O P) do
          {letter <> " KW", String.duplicate(letter, 11)}
        end

      seed_keywords!(specs)

      assert {:ok, result} = Keywords.rebuild_index()

      # One primary + two secondaries: 3 objects total.
      assert result.counts.inserted == 3
      assert result.counts.bumped == 0
      assert result.counts.unchanged == 0
      assert result.total_secondaries == 2
      assert result.primary == :inserted
      assert result.secondaries == [{1, :inserted}, {2, :inserted}]

      # Primary really is in the DB.
      primary =
        Repo.get_by(Object, name: "TAODCUSSPGM", sequence: 0, type: 0x0C, version: 1)

      assert primary != nil

      {:ok, decoded} = KeywordIndex.decode_primary(primary.contents)
      assert decoded.format_flag == 0x02
      assert decoded.keywords_per_secondary == 14
      # byte 15 is the total-secondary count, NOT a cap. 16 keywords
      # chunked by 14 = 2 secondaries.
      assert decoded.total_secondaries == 2
      # Boundary list is the last keyword of each secondary.
      # Keywords sorted A->P -> secondary 1 ends at "N KW" (14th),
      # secondary 2 ends at "P KW" (last of remainder).
      assert decoded.boundary_keywords == ["N KW", "P KW"]
    end

    test "re-rebuild with no keyword changes lands everything as :unchanged" do
      seed_keywords!([
        {"ADD MEMBER", "MSZA0000PG0"},
        {"BASEBALL", "SB000000PG0"}
      ])

      {:ok, _first} = Keywords.rebuild_index()
      {:ok, second} = Keywords.rebuild_index()

      # 2 keywords -> 1 secondary (chunk of 2 <= 14) + 1 primary = 2 rows.
      assert second.counts.inserted == 0
      assert second.counts.bumped == 0
      assert second.counts.unchanged == 2
      assert second.primary == :unchanged
    end

    test "adding a keyword that doesn't change the last keyword bumps only the secondary" do
      # "ONLY" is the last keyword in the one-and-only secondary.
      # Adding "NEW" keeps "ONLY" as the last keyword -> the primary's
      # boundary-keyword list is unchanged (still ["ONLY"]).
      # The secondary's entry list grows, so it bumps.
      seed_keywords!([{"ONLY", "OBJECT00000"}])

      {:ok, _first} = Keywords.rebuild_index()

      seed!("NEW", "NEWOBJ00000")
      {:ok, second} = Keywords.rebuild_index()

      assert second.primary == :unchanged
      assert second.counts.bumped == 1
      assert second.counts.unchanged == 1
    end

    test "adding a keyword that becomes the new last keyword bumps both primary and secondary" do
      seed_keywords!([{"ONLY", "OBJECT00000"}])

      {:ok, _first} = Keywords.rebuild_index()

      # "ZULU" sorts after "ONLY" -> changes the secondary's last
      # keyword from ONLY to ZULU -> primary's boundary list changes.
      seed!("ZULU", "ZULUOBJ0000")
      {:ok, second} = Keywords.rebuild_index()

      assert second.primary == :bumped
      assert second.counts.bumped == 2
      assert second.counts.unchanged == 0
    end

    test "boundary keywords round-trip through encode + decode byte-for-byte" do
      seed_keywords!([
        {"ADD MEMBER", "MSZA0000PG0"},
        {"BASEBALL", "SB000000PG0"},
        {"COSMETICS", "ICG00001PG0"},
        {"COSMOS", "TG000000PG0"}
      ])

      assert {:ok, _} = Keywords.rebuild_index()

      primary =
        Repo.get_by(Object, name: "TAODCUSSPGM", sequence: 0, type: 0x0C, version: 1)

      secondary =
        Repo.get_by(Object, name: "TAODCUKJD  ", sequence: 1, type: 0x0C, version: 1)

      # Round-trip each.
      {:ok, dp} = KeywordIndex.decode_primary(primary.contents)
      assert KeywordIndex.encode_primary(dp) == primary.contents

      {:ok, ds} = KeywordIndex.decode_secondary(secondary.contents)
      assert KeywordIndex.encode_secondary(ds) == secondary.contents

      # Prefix compression is wired through: COSMETICS -> COSMOS
      # shares "COSM" (4 chars).
      cosmos_entry = Enum.find(ds.entries, &(&1.keyword == "COSMOS"))
      assert cosmos_entry.prefix_length == 4
    end

    test "pick_chunk_size/1 keeps the default 14 until we approach the byte cap" do
      # Default 14-per-secondary until total > 14 x 255 = 3570.
      assert Keywords.pick_chunk_size(1) == 14
      assert Keywords.pick_chunk_size(3570) == 14

      # Past that, rebalance: ceil(total / 255) keywords per secondary
      # so the secondary-count byte doesn't overflow.
      assert Keywords.pick_chunk_size(3571) == 15
      assert Keywords.pick_chunk_size(10_000) == 40
    end
  end
end
