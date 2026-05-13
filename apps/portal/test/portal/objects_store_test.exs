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

defmodule Prodigy.Core.Objects.StoreTest do
  @moduledoc """
  Sanity coverage for the shared insert pipeline - `Admin.ObjectsTest`
  still exercises the full semantic matrix through its admin-facing
  wrapper. These tests pin the core contract: parse -> insert_or_bump
  -> keyword extraction across the three dispositions, all driven
  through the module its callers (portal admin, podbutil) use.
  """
  # Test lives in portal only because portal carries the DataCase;
  # the module under test (Prodigy.Core.Objects.Store) is in :core.
  use Prodigy.Portal.DataCase, async: true

  alias Prodigy.Core.Data.Service.Keyword, as: ServiceKeyword
  alias Prodigy.Core.Objects.Store

  defp name_bytes(s), do: s <> String.duplicate(" ", 11 - byte_size(s))

  defp build_blob(opts) do
    name = Elixir.Keyword.fetch!(opts, :name)
    version = Elixir.Keyword.get(opts, :version, 1)
    body = Elixir.Keyword.get(opts, :body, <<>>)
    <<cv_high, cv_low>> = <<0::3, version::13>>
    length = byte_size(body)

    <<name_bytes(name)::binary-size(11), 0, 0x04, length::16-little, cv_high, 0, cv_low>> <>
      body
  end

  defp keyword_segment(kw) do
    prev = :binary.copy(<<0>>, 13)
    guide = :binary.copy(<<0>>, 13)
    field = kw <> :binary.copy(<<0>>, 13 - byte_size(kw))
    payload = prev <> guide <> field
    <<0x71, 3 + byte_size(payload)::16-little>> <> payload
  end

  describe "parse_import_blob/1" do
    test "populates content_hash + keyword for a blob carrying a 0x71 segment" do
      blob = build_blob(name: "A", body: keyword_segment("NEWS"))
      assert {:ok, parsed} = Store.parse_import_blob(blob)
      assert parsed.keyword == "NEWS"
      assert byte_size(parsed.content_hash) == 32
    end

    test "degrades to keyword: nil on malformed segment streams" do
      # A non-empty body that isn't a valid segment frame.
      blob = build_blob(name: "A", body: <<0x00, 0x00, 0x00>>)
      assert {:ok, %{keyword: nil}} = Store.parse_import_blob(blob)
    end

    test "rejects too-short blobs" do
      assert Store.parse_import_blob(<<0, 1, 2>>) == {:error, :too_short}
    end
  end

  describe "insert_or_bump/1" do
    test "inserts fresh rows at their declared version" do
      {:ok, a} = Store.parse_import_blob(build_blob(name: "A", version: 7))
      assert {:ok, %{inserted: [%{version: 7}], bumped: [], unchanged: []}} =
               Store.insert_or_bump([a])
    end

    test "same content re-uploads are :unchanged" do
      {:ok, p} = Store.parse_import_blob(build_blob(name: "SAME"))
      assert {:ok, _} = Store.insert_or_bump([p])

      {:ok, p_again} = Store.parse_import_blob(build_blob(name: "SAME", version: 42))
      assert {:ok, %{unchanged: [_], inserted: [], bumped: []}} =
               Store.insert_or_bump([p_again])
    end

    test "different content bumps to max+1, wrapping at 8191" do
      {:ok, first} =
        Store.parse_import_blob(build_blob(name: "WRAP", version: 8191, body: <<0xAA>>))

      assert {:ok, _} = Store.insert_or_bump([first])

      {:ok, second} =
        Store.parse_import_blob(build_blob(name: "WRAP", version: 0, body: <<0xBB>>))

      assert {:ok, %{bumped: [%{version: 0, previous_version: 8191}]}} =
               Store.insert_or_bump([second])
    end

    test "keyword extraction populates the keyword table and rollbacks on collision" do
      {:ok, a} = Store.parse_import_blob(build_blob(name: "A", body: keyword_segment("DUP")))
      assert {:ok, _} = Store.insert_or_bump([a])

      {:ok, b} = Store.parse_import_blob(build_blob(name: "B", body: keyword_segment("DUP")))
      {:ok, ok} = Store.parse_import_blob(build_blob(name: "CLEAN"))

      assert {:error, {:keyword_collision, "DUP", owner, newcomer}} =
               Store.insert_or_bump([ok, b])

      assert owner =~ "A"
      assert newcomer =~ "B"
      # CLEAN was in the batch but must NOT have landed.
      refute Prodigy.Core.Data.Repo.get_by(Prodigy.Core.Data.Service.Object,
               name: "CLEAN      ",
               sequence: 0,
               type: 0x04,
               version: 1
             )
    end

    test ":skip mode lands the object without the keyword and records the collision" do
      {:ok, a} = Store.parse_import_blob(build_blob(name: "A", body: keyword_segment("DUP")))
      assert {:ok, _} = Store.insert_or_bump([a])

      {:ok, b} = Store.parse_import_blob(build_blob(name: "B", body: keyword_segment("DUP")))

      assert {:ok, result} = Store.insert_or_bump([b], on_keyword_collision: :skip)

      # Object B landed, but with keyword: nil (didn't claim).
      assert [%{name: name, keyword: nil}] = result.inserted
      assert String.trim(name) == "B"

      # Collision surfaced.
      assert [%{keyword: "DUP", owner_obj_id: owner, new_obj_id: newcomer}] =
               result.skipped_keywords

      assert owner =~ "A"
      assert newcomer =~ "B"

      # Keyword table still points at A only.
      assert [%{object_name: "A          "}] = Repo.all(ServiceKeyword)
    end

    test "a re-upload that drops the keyword deletes its index row" do
      {:ok, v1} = Store.parse_import_blob(build_blob(name: "K", body: keyword_segment("WAS")))
      {:ok, _} = Store.insert_or_bump([v1])
      assert [_] = Prodigy.Core.Data.Repo.all(ServiceKeyword)

      {:ok, v2} = Store.parse_import_blob(build_blob(name: "K", body: <<>>))
      assert {:ok, %{bumped: [_]}} = Store.insert_or_bump([v2])
      assert Prodigy.Core.Data.Repo.all(ServiceKeyword) == []
    end
  end

  describe "keywords_changed? flag" do
    test "empty batch -> false" do
      assert {:ok, %{keywords_changed?: false}} = Store.insert_or_bump([])
    end

    test "insert of an object with no keyword -> false" do
      {:ok, p} = Store.parse_import_blob(build_blob(name: "NOKW"))
      assert {:ok, %{keywords_changed?: false, inserted: [_]}} = Store.insert_or_bump([p])
    end

    test "insert of an object with a keyword -> true" do
      {:ok, p} = Store.parse_import_blob(build_blob(name: "A", body: keyword_segment("HELLO")))
      assert {:ok, %{keywords_changed?: true, inserted: [_]}} = Store.insert_or_bump([p])
    end

    test "re-upload of identical content -> false (unchanged)" do
      {:ok, p} = Store.parse_import_blob(build_blob(name: "A", body: keyword_segment("HI")))
      assert {:ok, %{keywords_changed?: true}} = Store.insert_or_bump([p])
      assert {:ok, %{keywords_changed?: false, unchanged: [_]}} = Store.insert_or_bump([p])
    end

    test "bump that keeps the same keyword text -> false" do
      # Same keyword on both versions - the object bytes change via the
      # version field but the keyword stays identical.
      {:ok, v1} =
        Store.parse_import_blob(build_blob(name: "A", version: 1, body: keyword_segment("NEWS")))

      assert {:ok, %{keywords_changed?: true}} = Store.insert_or_bump([v1])

      # Different content (different body) but same extracted keyword.
      body2 = keyword_segment("NEWS") <> <<0x00>>
      {:ok, v2} = Store.parse_import_blob(build_blob(name: "A", version: 1, body: body2))

      assert {:ok, %{keywords_changed?: false, bumped: [_]}} = Store.insert_or_bump([v2])
    end

    test "bump that changes the keyword text -> true" do
      {:ok, v1} =
        Store.parse_import_blob(build_blob(name: "A", body: keyword_segment("OLD")))

      {:ok, _} = Store.insert_or_bump([v1])

      {:ok, v2} =
        Store.parse_import_blob(build_blob(name: "A", body: keyword_segment("NEW")))

      assert {:ok, %{keywords_changed?: true, bumped: [_]}} = Store.insert_or_bump([v2])
    end

    test "bump that drops the keyword -> true" do
      {:ok, v1} =
        Store.parse_import_blob(build_blob(name: "A", body: keyword_segment("BYE")))

      {:ok, _} = Store.insert_or_bump([v1])

      {:ok, v2} = Store.parse_import_blob(build_blob(name: "A", body: <<>>))
      assert {:ok, %{keywords_changed?: true, bumped: [_]}} = Store.insert_or_bump([v2])
    end

    test "mixed batch - any true row wins" do
      {:ok, noisy} =
        Store.parse_import_blob(build_blob(name: "LOUD", body: keyword_segment("LOUD")))

      {:ok, quiet} = Store.parse_import_blob(build_blob(name: "SILENT"))

      assert {:ok, %{keywords_changed?: true, inserted: [_, _]}} =
               Store.insert_or_bump([quiet, noisy])
    end

    test "skip-mode collision that steals a nil-to-keyword transition -> false" do
      # A claims keyword first.
      {:ok, a} = Store.parse_import_blob(build_blob(name: "A", body: keyword_segment("DUP")))
      {:ok, _} = Store.insert_or_bump([a])

      # B tries to claim DUP but loses (skip-mode) - B never had a
      # keyword before, and it still doesn't. No change.
      {:ok, b} = Store.parse_import_blob(build_blob(name: "B", body: keyword_segment("DUP")))

      assert {:ok, %{keywords_changed?: false, inserted: [_]}} =
               Store.insert_or_bump([b], on_keyword_collision: :skip)
    end
  end

  describe "delete/4 - re-derive keyword from the highest remaining version" do
    defp insert!(opts) do
      {:ok, parsed} = Store.parse_import_blob(build_blob(opts))
      {:ok, _} = Store.insert_or_bump([parsed])
      parsed
    end

    defp keyword_row_for(name, seq, type) do
      import Ecto.Query

      from(k in ServiceKeyword,
        where:
          k.object_name == ^name_bytes(name) and k.object_sequence == ^seq and
            k.object_type == ^type,
        select: k.keyword
      )
      |> Repo.one()
    end

    test "sole version with keyword: keyword row is removed, keywords_changed? true" do
      _ = insert!(name: "A", version: 1, body: keyword_segment("NEWS"))

      assert {:ok, %{keywords_changed?: true}} =
               Store.delete(name_bytes("A"), 0, 0x04, 1)

      refute keyword_row_for("A", 0, 0x04)
    end

    test "sole version without keyword: no change, keywords_changed? false" do
      _ = insert!(name: "PLAIN", version: 1)

      assert {:ok, %{keywords_changed?: false}} =
               Store.delete(name_bytes("PLAIN"), 0, 0x04, 1)

      refute keyword_row_for("PLAIN", 0, 0x04)
    end

    test "delete newer version whose predecessor carried the same keyword: no change, keywords_changed? false" do
      # Version bytes alone don't change content_hash (canonicalize
      # zeros them). Append an extra byte in v2's body to force a real
      # bump to version 2.
      _v1 = insert!(name: "A", version: 1, body: keyword_segment("NEWS"))
      _v2 = insert!(name: "A", version: 1, body: keyword_segment("NEWS") <> <<0>>)

      assert {:ok, %{keywords_changed?: false}} =
               Store.delete(name_bytes("A"), 0, 0x04, 2)

      # Row still points at NEWS for (A, 0, 0x04).
      assert keyword_row_for("A", 0, 0x04) == "NEWS"
    end

    test "delete newer version; predecessor has no keyword: row removed, keywords_changed? true" do
      _v1 = insert!(name: "A", version: 1)
      _v2 = insert!(name: "A", version: 1, body: keyword_segment("NEWS"))

      assert {:ok, %{keywords_changed?: true}} =
               Store.delete(name_bytes("A"), 0, 0x04, 2)

      refute keyword_row_for("A", 0, 0x04)
    end

    test "delete newer version; predecessor carried a different keyword: row replaced, keywords_changed? true" do
      _v1 = insert!(name: "A", version: 1, body: keyword_segment("OLD"))
      _v2 = insert!(name: "A", version: 1, body: keyword_segment("NEW"))

      assert {:ok, %{keywords_changed?: true}} =
               Store.delete(name_bytes("A"), 0, 0x04, 2)

      assert keyword_row_for("A", 0, 0x04) == "OLD"
    end

    test "delete not-found returns :not_found without touching keywords" do
      _ = insert!(name: "A", version: 1, body: keyword_segment("NEWS"))
      assert :not_found = Store.delete(name_bytes("A"), 0, 0x04, 999)
      assert keyword_row_for("A", 0, 0x04) == "NEWS"
    end
  end
end
