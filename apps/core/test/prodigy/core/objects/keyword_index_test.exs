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

defmodule Prodigy.Core.Objects.KeywordIndexTest do
  @moduledoc """
  Golden-file tests for the keyword-index decoder. Four real DOS-
  client cached binaries under `test/fixtures/keyword_index/`:

    * `TAODCUSSPGM_bruce.bin` / `TAODCUSSPGM_cacheread.bin` - two
      primaries from two different installations. Byte-identical;
      decoding both asserts the same struct fields.
    * `TAODCUKJD_seq53.bin` - a secondary from a floppy-cache
      (MAGID -> MAILING LIST range). Shows prefix compression in use.
    * `TAODCUKJD_seq16.bin` - a secondary from another installation
      (CONTROL FIN -> CR AIDS range). Different compression pattern
      (COSM-family keywords share long prefixes).

  This file only asserts the decode side; round-trip byte-equality
  tests against these fixtures are a possible future addition.
  """
  use ExUnit.Case, async: true

  alias Prodigy.Core.Objects.KeywordIndex
  alias Prodigy.Core.Objects.KeywordIndex.{Entry, Primary, Secondary}

  @fixtures Path.join([__DIR__, "..", "..", "..", "fixtures", "keyword_index"])

  defp read_fixture(name), do: File.read!(Path.join(@fixtures, name))

  # --- primary -------------------------------------------------------

  describe "decode_primary/1 - TAODCUSSPGM" do
    setup do
      {:ok, bruce_primary: read_fixture("TAODCUSSPGM_bruce.bin"),
       cacheread_primary: read_fixture("TAODCUSSPGM_cacheread.bin")}
    end

    test "decodes header constants matching the real samples",
         %{bruce_primary: blob} do
      assert {:ok, %Primary{} = p} = KeywordIndex.decode_primary(blob)

      # Format constants observed in the real samples: 0x02 flag
      # (meaning still unknown); 0x0E = 14 keywords/secondary; 0x61 = 97
      # cap.
      assert p.format_flag == 0x02
      assert p.keywords_per_secondary == 14
      assert p.secondary_name_template == "TAODCUKJD  "
      assert p.first_seq_byte == 0x01
      assert p.secondary_type == 0x0C
      # XXPXKWRD label_358/373 wraps the current-secondary iterator
      # when it exceeds this byte. Production's primary has exactly
      # 97 boundary entries, matching this value - confirming it's
      # the actual total-secondary count, not a cap.
      assert p.total_secondaries == 0x61

      # Object-level metadata from the 18-byte header.
      assert p.version == 775
      assert p.candidacy == 0
    end

    test "boundary-keyword list starts A-alphabetical and ends with the ZZZ backstop",
         %{bruce_primary: blob} do
      {:ok, %Primary{boundary_keywords: kws}} = KeywordIndex.decode_primary(blob)

      assert [first | _] = kws
      assert first == "ADD MEMBER"
      assert List.last(kws) == "ZZZZZZZZZZZZZ"
    end

    test "boundary keywords are sorted and each size <= 13",
         %{bruce_primary: blob} do
      {:ok, %Primary{boundary_keywords: kws}} = KeywordIndex.decode_primary(blob)

      assert kws == Enum.sort(kws)
      assert Enum.all?(kws, &(byte_size(&1) <= 13))
    end

    test "both installations produce the same Primary struct",
         %{bruce_primary: bruce, cacheread_primary: cacheread} do
      {:ok, p1} = KeywordIndex.decode_primary(bruce)
      {:ok, p2} = KeywordIndex.decode_primary(cacheread)
      assert p1 == p2
    end

    test "total_secondaries matches the boundary-keyword count exactly",
         %{bruce_primary: blob} do
      # Production's byte-15 value equals the number of boundary
      # entries - proof that byte 15 is the wrap point, not a cap.
      {:ok, p} = KeywordIndex.decode_primary(blob)
      assert length(p.boundary_keywords) == p.total_secondaries
    end
  end

  # --- secondary (seq 53, MAGID range) -------------------------------

  describe "decode_secondary/1 - TAODCUKJD seq 53 (MAGID range)" do
    setup do
      {:ok, blob: read_fixture("TAODCUKJD_seq53.bin")}
    end

    test "decodes header + 12 entries", %{blob: blob} do
      assert {:ok, %Secondary{} = s} = KeywordIndex.decode_secondary(blob)

      assert s.format_flag == 0x02
      assert s.sequence == 53
      assert s.version == 775
      assert s.candidacy == 0
      assert length(s.entries) == 12
    end

    test "first entry is MAGID at its full length (prefix_length 0)",
         %{blob: blob} do
      {:ok, s} = KeywordIndex.decode_secondary(blob)

      assert %Entry{
               keyword: "MAGID",
               prefix_length: 0,
               target_name: "5A000000PG ",
               target_sequence: 1,
               target_type: 4
             } = hd(s.entries)
    end

    test "prefix compression reconstructs MAIL -> MAILBOX -> MAILING LIST correctly",
         %{blob: blob} do
      {:ok, s} = KeywordIndex.decode_secondary(blob)
      kws = Enum.map(s.entries, & &1.keyword)

      # Sequential run from the real file.
      assert Enum.slice(kws, 0, 4) == ["MAGID", "MAIL", "MAILBOX", "MAILING LIST"]
    end

    test "all entries are alphabetically sorted", %{blob: blob} do
      {:ok, s} = KeywordIndex.decode_secondary(blob)
      kws = Enum.map(s.entries, & &1.keyword)
      assert kws == Enum.sort(kws)
    end

    test "prefix_length never exceeds the previous keyword's length",
         %{blob: blob} do
      {:ok, s} = KeywordIndex.decode_secondary(blob)

      s.entries
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert b.prefix_length <= byte_size(a.keyword),
               "entry #{b.keyword} has prefix_length=#{b.prefix_length} but previous was #{a.keyword}"
      end)
    end

    test "target_name fields are always 11 bytes, space-padded ASCII",
         %{blob: blob} do
      {:ok, s} = KeywordIndex.decode_secondary(blob)

      for entry <- s.entries do
        assert byte_size(entry.target_name) == 11
        assert String.printable?(entry.target_name)
      end
    end
  end

  # --- secondary (seq 16, CONTROL FIN range) -------------------------

  describe "decode_secondary/1 - TAODCUKJD seq 16 (CONTROL FIN range)" do
    setup do
      {:ok, blob: read_fixture("TAODCUKJD_seq16.bin")}
    end

    test "sequence byte matches the filename", %{blob: blob} do
      {:ok, s} = KeywordIndex.decode_secondary(blob)
      assert s.sequence == 16
    end

    test "first entry is CONTROL FIN (11 bytes, full)", %{blob: blob} do
      {:ok, s} = KeywordIndex.decode_secondary(blob)
      assert hd(s.entries).keyword == "CONTROL FIN"
      assert hd(s.entries).prefix_length == 0
    end

    test "COSMOS-family prefix compression: the encoder picks the longest shared prefix",
         %{blob: blob} do
      {:ok, s} = KeywordIndex.decode_secondary(blob)
      kws = Enum.map(s.entries, & &1.keyword)

      # From the real file - contiguous run of keywords sharing "CO"
      # progressing to longer prefixes.
      assert "COOKBOOK" in kws
      assert "CORIAN" in kws
      assert "COSMETICS" in kws
      assert "COSMOS" in kws

      # After COSMOS, prefix_length jumps to 6 ("COSMOS") and the next
      # keyword's suffix happens to start with a space. The decoder
      # reconstructs it verbatim.
      post_cosmos_idx = Enum.find_index(kws, &(&1 == "COSMOS"))
      next = Enum.at(kws, post_cosmos_idx + 1)
      assert String.starts_with?(next, "COSMOS ")
    end
  end

  # --- round-trip (encode/decode) ------------------------------------

  describe "encode_primary/1 - round-trip against golden fixtures" do
    test "bruce-installation primary round-trips byte-for-byte" do
      blob = read_fixture("TAODCUSSPGM_bruce.bin")
      {:ok, decoded} = KeywordIndex.decode_primary(blob)
      assert KeywordIndex.encode_primary(decoded) == blob
    end

    test "cacheread-installation primary round-trips byte-for-byte" do
      blob = read_fixture("TAODCUSSPGM_cacheread.bin")
      {:ok, decoded} = KeywordIndex.decode_primary(blob)
      assert KeywordIndex.encode_primary(decoded) == blob
    end
  end

  describe "encode_secondary/1 - round-trip against golden fixtures" do
    test "seq 53 (MAGID range) round-trips byte-for-byte" do
      blob = read_fixture("TAODCUKJD_seq53.bin")
      {:ok, decoded} = KeywordIndex.decode_secondary(blob)
      assert KeywordIndex.encode_secondary(decoded) == blob
    end

    test "seq 16 (CONTROL FIN range) round-trips byte-for-byte" do
      blob = read_fixture("TAODCUKJD_seq16.bin")
      {:ok, decoded} = KeywordIndex.decode_secondary(blob)
      assert KeywordIndex.encode_secondary(decoded) == blob
    end
  end

  # --- build_secondary/2 (prefix-compression picker) ------------------

  describe "build_secondary/2 - prefix compression from raw keywords" do
    defp target(name), do: {String.pad_trailing(name, 11, " "), 1, 0x04}

    test "first entry has prefix_length = 0, full keyword in suffix" do
      s =
        KeywordIndex.build_secondary(
          [{"NEWS", target("NH000000PG")}],
          sequence: 1
        )

      assert [%Entry{keyword: "NEWS", prefix_length: 0}] = s.entries
    end

    test "picks the longest common prefix between adjacent keywords" do
      s =
        KeywordIndex.build_secondary(
          [
            {"MAGID", target("5A000000PG")},
            {"MAIL", target("MSZB0000MA")},
            {"MAILBOX", target("MSZB0000MA")},
            {"MAILING LIST", target("MSZP0000MA")}
          ],
          sequence: 1
        )

      # MAGID -> MAIL shares "MA" (2); MAIL -> MAILBOX shares "MAIL" (4);
      # MAILBOX -> MAILING LIST shares "MAIL" (4).
      assert Enum.map(s.entries, & &1.prefix_length) == [0, 2, 4, 4]
    end

    test "encode/decode round-trip of a freshly-built secondary" do
      built =
        KeywordIndex.build_secondary(
          [
            {"ADD MEMBER", target("MSZA0000MA")},
            {"ADDRESS BOOK", target("MSZA0000MA")},
            {"BASEBALL", target("SB000000PG")}
          ],
          sequence: 1,
          name: "TAODCUKJD  ",
          version: 1,
          candidacy: 0
        )

      blob = KeywordIndex.encode_secondary(built)
      assert {:ok, decoded} = KeywordIndex.decode_secondary(blob)
      assert Enum.map(decoded.entries, & &1.keyword) == [
               "ADD MEMBER",
               "ADDRESS BOOK",
               "BASEBALL"
             ]

      # ADD MEMBER vs ADDRESS BOOK share only "ADD" (3 chars); the
      # 4th char is space vs 'R'. BASEBALL shares nothing with
      # ADDRESS BOOK.
      assert Enum.map(decoded.entries, & &1.prefix_length) == [0, 3, 0]
    end

    test "identical prefix chains compress all the way (COSMETICS -> COSMOS)" do
      s =
        KeywordIndex.build_secondary(
          [
            {"COSMETICS", target("ICG00001PG")},
            {"COSMOS", target("TG000000PG")}
          ],
          sequence: 1
        )

      # COSM is 4 shared chars.
      assert [_, %Entry{prefix_length: 4}] = s.entries
    end
  end

  # --- error paths ---------------------------------------------------

  describe "error cases" do
    test "decode_primary/1 on a too-short blob returns :too_short" do
      assert {:error, _} = KeywordIndex.decode_primary(<<0, 1, 2>>)
    end

    test "decode_secondary/1 on a blob whose segment isn't PROGRAM_DATA" do
      # Craft an 18-byte header + a non-0x61 segment so the extractor
      # bails with :unexpected_segment_type.
      header = :binary.copy(<<0>>, 18)
      bogus_segment = <<0x10, 3::16-little>>
      assert {:error, {:unexpected_segment_type, 0x10}} =
               KeywordIndex.decode_secondary(header <> bogus_segment)
    end
  end
end
