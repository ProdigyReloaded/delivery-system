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

defmodule Prodigy.Portal.Admin.ObjectsTest do
  use Prodigy.Portal.DataCase, async: true

  # Aliased as ObjectKeyword because the tests also use Elixir's
  # built-in `Keyword` module (fetch!/get) in their fixture helpers.
  alias Prodigy.Core.Data.Service.Keyword, as: ObjectKeyword
  alias Prodigy.Core.Data.Service.Object
  alias Prodigy.Portal.Admin.Objects

  # --- blob / fixture helpers ---------------------------------------

  defp name_bytes(s) when byte_size(s) <= 11,
    do: s <> String.duplicate(" ", 11 - byte_size(s))

  # Build a Prodigy-format object blob. Body defaults to empty (no
  # segments); pass `:body` to embed segment bytes or `:keyword` to
  # auto-build a 0x71 Keyword Navigation segment.
  defp build_blob(opts) do
    name = Keyword.fetch!(opts, :name)
    sequence = Keyword.get(opts, :sequence, 0)
    type = Keyword.get(opts, :type, 0x0)
    version = Keyword.get(opts, :version, 1)
    candidacy = Keyword.get(opts, :candidacy, 0)
    body = Keyword.get(opts, :body, keyword_body(opts))

    <<cv_high, cv_low>> = <<candidacy::3, version::13>>
    length = byte_size(body)

    <<name_bytes(name)::binary-size(11), sequence, type, length::16-little, cv_high, 0, cv_low>> <>
      body
  end

  # 0x71 Keyword Navigation segment payload: 13 PREV_MENU + 13
  # GUIDE_BFD + up to 13 CURRENT_KEYWORD, each null-padded.
  defp keyword_body(opts) do
    case Keyword.get(opts, :keyword) do
      nil ->
        <<>>

      kw ->
        prev = :binary.copy(<<0>>, 13)
        guide = :binary.copy(<<0>>, 13)
        keyword_field = kw <> :binary.copy(<<0>>, 13 - byte_size(kw))
        payload = prev <> guide <> keyword_field

        seg_length = 3 + byte_size(payload)
        <<0x71, seg_length::16-little>> <> payload
    end
  end

  # --- metadata helpers ---------------------------------------------

  describe "type_label/1" do
    test "labels every known type code" do
      assert Objects.type_label(0x0) == "Page Format"
      assert Objects.type_label(0x4) == "Page Template"
      assert Objects.type_label(0x8) == "Page Element"
      assert Objects.type_label(0xC) == "Program"
      assert Objects.type_label(0xE) == "Window"
    end

    test "falls back to hex byte for unknown types" do
      assert Objects.type_label(0x42) == "0x42"
    end
  end

  describe "known_types/0" do
    test "returns the five known type codes in a stable order" do
      assert Objects.known_types() == [0x0, 0x4, 0x8, 0xC, 0xE]
    end
  end

  # --- parse_import_blob --------------------------------------------

  describe "parse_import_blob/1" do
    test "extracts name, sequence, type, version, contents, hash, keyword" do
      blob = build_blob(name: "TESTPAGE   ", sequence: 3, type: 0x8, version: 42)

      assert {:ok, parsed} = Objects.parse_import_blob(blob)
      assert parsed.name == "TESTPAGE   "
      assert parsed.sequence == 3
      assert parsed.type == 0x8
      assert parsed.version == 42
      assert parsed.contents == blob
      assert is_binary(parsed.content_hash)
      assert byte_size(parsed.content_hash) == 32
      assert parsed.keyword == nil
    end

    test "populates :keyword when the body carries a 0x71 segment" do
      blob = build_blob(name: "KW", keyword: "NEWS")
      assert {:ok, %{keyword: "NEWS"}} = Objects.parse_import_blob(blob)
    end

    test "same content at different versions produces the same content_hash" do
      a = build_blob(name: "A", version: 1)
      b = build_blob(name: "A", version: 5)

      {:ok, pa} = Objects.parse_import_blob(a)
      {:ok, pb} = Objects.parse_import_blob(b)
      assert pa.content_hash == pb.content_hash
    end

    test "rejects blobs shorter than the 18-byte header" do
      assert Objects.parse_import_blob(<<0>>) == {:error, :too_short}
      assert Objects.parse_import_blob(<<>>) == {:error, :too_short}
    end
  end

  # --- insert_many: new contract ------------------------------------

  describe "insert_many/1 - inserts / bumps / unchanged" do
    test "empty input returns an empty result map" do
      assert {:ok, %{inserted: [], bumped: [], unchanged: []}} = Objects.insert_many([])
      assert Objects.list() == []
    end

    test "new (name, seq, type) lands as :inserted at the uploaded version" do
      {:ok, a} = Objects.parse_import_blob(build_blob(name: "A", version: 4))
      {:ok, b} = Objects.parse_import_blob(build_blob(name: "B", version: 1))

      assert {:ok, result} = Objects.insert_many([a, b])
      assert Enum.map(result.inserted, & &1.name) == ["A          ", "B          "]
      assert Enum.map(result.inserted, & &1.version) == [4, 1]
      assert result.bumped == []
      assert result.unchanged == []
      assert length(Objects.list()) == 2
    end

    test "same content at same (name, seq, type) is :unchanged" do
      {:ok, a} = Objects.parse_import_blob(build_blob(name: "SAME", version: 1))
      assert {:ok, _} = Objects.insert_many([a])

      {:ok, a_again} = Objects.parse_import_blob(build_blob(name: "SAME", version: 999))
      assert {:ok, result} = Objects.insert_many([a_again])

      assert [%{name: n, version: 1}] = result.unchanged
      assert String.trim(n) == "SAME"
      assert result.inserted == []
      assert result.bumped == []
      # Exactly one row in the DB.
      assert length(Objects.list()) == 1
    end

    test "different content at the same (name, seq, type) is :bumped to max + 1" do
      {:ok, v1} = Objects.parse_import_blob(build_blob(name: "BUMP", version: 3, body: <<1, 2>>))
      assert {:ok, _} = Objects.insert_many([v1])

      {:ok, v2} =
        Objects.parse_import_blob(build_blob(name: "BUMP", version: 999, body: <<5, 6>>))

      assert {:ok, result} = Objects.insert_many([v2])
      assert [%{version: 4, previous_version: 3}] = result.bumped
      assert result.inserted == []
      # Both rows present.
      assert Objects.list() |> Enum.map(& &1.version) |> Enum.sort() == [3, 4]
    end

    test "version wraps from 8191 to 0 on auto-bump" do
      {:ok, v1} =
        Objects.parse_import_blob(build_blob(name: "WRAP", version: 8191, body: <<0xAA>>))

      assert {:ok, _} = Objects.insert_many([v1])

      {:ok, v2} =
        Objects.parse_import_blob(build_blob(name: "WRAP", version: 0, body: <<0xBB>>))

      assert {:ok, result} = Objects.insert_many([v2])
      assert [%{version: 0, previous_version: 8191}] = result.bumped
    end

    test "broadcasts :objects_upserted after a successful commit" do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, Objects.topic())
      {:ok, a} = Objects.parse_import_blob(build_blob(name: "BCAST"))
      {:ok, _} = Objects.insert_many([a])
      assert_receive :objects_upserted, 500
    end
  end

  describe "insert_many/1 - keyword indexing" do
    test "inserts a keyword row when the upload carries a 0x71 segment" do
      {:ok, a} = Objects.parse_import_blob(build_blob(name: "KW", keyword: "NEWS"))
      assert {:ok, result} = Objects.insert_many([a])
      assert [%{keyword: "NEWS"}] = result.inserted

      assert [row] = Repo.all(ObjectKeyword)
      assert row.keyword == "NEWS"
      assert String.trim(row.object_name) == "KW"
    end

    test "re-uploading a different version with a different keyword replaces the mapping" do
      {:ok, v1} = Objects.parse_import_blob(build_blob(name: "RK", keyword: "OLD"))
      {:ok, _} = Objects.insert_many([v1])

      {:ok, v2} =
        Objects.parse_import_blob(
          build_blob(name: "RK", body: keyword_segment_body("NEW"))
        )

      assert {:ok, _} = Objects.insert_many([v2])

      assert [%ObjectKeyword{keyword: "NEW"}] = Repo.all(ObjectKeyword)
    end

    test "re-uploading a new version that drops the keyword removes it from the index" do
      {:ok, v1} = Objects.parse_import_blob(build_blob(name: "LOSE", keyword: "WAS"))
      {:ok, _} = Objects.insert_many([v1])
      assert [_] = Repo.all(ObjectKeyword)

      # Upload different content with no keyword segment.
      {:ok, v2} = Objects.parse_import_blob(build_blob(name: "LOSE", body: <<0xEE>>))
      assert {:ok, %{bumped: [_]}} = Objects.insert_many([v2])

      assert Repo.all(ObjectKeyword) == []
    end

    test "collision with a different object's keyword rolls the whole transaction back" do
      {:ok, owner} = Objects.parse_import_blob(build_blob(name: "OWNER", keyword: "DUP"))
      {:ok, _} = Objects.insert_many([owner])

      {:ok, conflict} = Objects.parse_import_blob(build_blob(name: "OTHER", keyword: "DUP"))
      {:ok, innocent} = Objects.parse_import_blob(build_blob(name: "CLEAN", version: 1))

      assert {:error, {:keyword_collision, "DUP", owner_id, new_id}} =
               Objects.insert_many([innocent, conflict])

      assert owner_id =~ "OWNER"
      assert new_id =~ "OTHER"
      # CLEAN must not have landed.
      refute Objects.list() |> Enum.any?(&(String.trim(&1.name) == "CLEAN"))
    end
  end

  # Build a 0x71 segment-carrying body from a caller-supplied keyword.
  defp keyword_segment_body(kw) do
    prev = :binary.copy(<<0>>, 13)
    guide = :binary.copy(<<0>>, 13)
    keyword_field = kw <> :binary.copy(<<0>>, 13 - byte_size(kw))
    payload = prev <> guide <> keyword_field
    <<0x71, 3 + byte_size(payload)::16-little>> <> payload
  end

  # --- list / get_blob / delete -------------------------------------

  describe "list/0" do
    test "orders by name asc, sequence asc, type asc, version desc" do
      # Seed distinct composite keys first, then trigger an auto-bump
      # on (A,0,0) so there are two versions sharing a key - that's
      # what the DESC-within-a-key ordering exercises.
      for {n, s, t, v, body_tag} <- [
            {"B", 0, 0x0, 1, 1},
            {"A", 1, 0x0, 1, 2},
            {"A", 0, 0x4, 2, 3},
            {"A", 0, 0x0, 3, 4}
          ] do
        {:ok, p} =
          Objects.parse_import_blob(
            build_blob(name: n, sequence: s, type: t, version: v, body: <<body_tag>>)
          )

        {:ok, _} = Objects.insert_many([p])
      end

      # Different content at (A,0,0) -> bumped from 3 to 4.
      {:ok, bump} =
        Objects.parse_import_blob(
          build_blob(name: "A", sequence: 0, type: 0x0, version: 99, body: <<5>>)
        )

      {:ok, %{bumped: [_]}} = Objects.insert_many([bump])

      ordered =
        Objects.list() |> Enum.map(&{String.trim(&1.name), &1.sequence, &1.type, &1.version})

      assert ordered == [
               {"A", 0, 0x0, 4},
               {"A", 0, 0x0, 3},
               {"A", 0, 0x4, 2},
               {"A", 1, 0x0, 1},
               {"B", 0, 0x0, 1}
             ]
    end

    test "includes size (octet_length) but not the contents blob" do
      # Wrap 125 bytes of filler inside a single valid segment so the
      # body parses cleanly (18 header + 3 frame + 125 payload = 146).
      filler = :binary.copy(<<0xAB>>, 125)
      segment = <<0x01, 128::16-little>> <> filler

      {:ok, p} = Objects.parse_import_blob(build_blob(name: "SIZE", body: segment))
      {:ok, _} = Objects.insert_many([p])

      [row] = Objects.list()
      assert row.size == 146
      refute Map.has_key?(row, :contents)
    end
  end

  describe "get_blob/4 + delete/4" do
    test "get_blob returns the full row including contents" do
      blob = build_blob(name: "GET", version: 3)
      {:ok, p} = Objects.parse_import_blob(blob)
      {:ok, _} = Objects.insert_many([p])

      assert %Object{contents: ^blob} = Objects.get_blob(p.name, p.sequence, p.type, p.version)
    end

    test "get_blob returns nil when no such row exists" do
      assert Objects.get_blob("NOPE       ", 0, 0x0, 1) == nil
    end

    test "delete removes the row and returns {object, keywords_changed?}" do
      {:ok, p} = Objects.parse_import_blob(build_blob(name: "DEL"))
      {:ok, _} = Objects.insert_many([p])

      assert {:ok, %{object: %Object{}, keywords_changed?: false}} =
               Objects.delete(p.name, p.sequence, p.type, p.version)

      assert Objects.list() == []
    end

    test "delete returns :not_found on a missing row" do
      assert Objects.delete("MISSING    ", 0, 0x0, 1) == :not_found
    end

    test "delete broadcasts :objects_deleted" do
      Phoenix.PubSub.subscribe(Prodigy.Core.PubSub, Objects.topic())
      {:ok, p} = Objects.parse_import_blob(build_blob(name: "BDEL"))
      {:ok, _} = Objects.insert_many([p])
      assert_receive :objects_upserted, 500

      {:ok, _} = Objects.delete(p.name, p.sequence, p.type, p.version)
      assert_receive :objects_deleted, 500
    end
  end
end
