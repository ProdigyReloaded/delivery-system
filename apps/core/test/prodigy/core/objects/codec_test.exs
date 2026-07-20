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

defmodule Prodigy.Core.Objects.CodecTest do
  use ExUnit.Case, async: true

  alias Prodigy.Core.Objects.Codec
  alias Prodigy.Core.Objects.Codec.{Header, Segment}

  # Build a valid object blob with the caller's header + body.
  # Candidacy / version are encoded the way the header codec expects.
  defp build(opts \\ []) do
    name = Keyword.get(opts, :name, "PAGE1      ") |> String.pad_trailing(11, " ")
    sequence = Keyword.get(opts, :sequence, 0)
    type = Keyword.get(opts, :type, 0x04)
    candidacy = Keyword.get(opts, :candidacy, 0)
    version = Keyword.get(opts, :version, 1)
    set_size = Keyword.get(opts, :set_size, 0)
    body = Keyword.get(opts, :body, <<>>)

    <<cv_high, cv_low>> = <<candidacy::3, version::13>>
    length = 18 + byte_size(body)

    <<name::binary-size(11), sequence, type, length::16-little, cv_high, set_size, cv_low>> <> body
  end

  # Build a segment frame: 1-byte type, 2-byte LE length (inclusive),
  # payload. For the walker tests.
  defp frame(type, payload) do
    length = 3 + byte_size(payload)
    <<type, length::16-little, payload::binary>>
  end

  # Build the 0x71 Keyword Navigation payload: 13 PREV_MENU +
  # 13 GUIDE_BFD + up to 13 CURRENT_KEYWORD, each null-padded on the
  # right (the Java reader stops at the first null).
  defp kwnav(opts) do
    # Wire layout: [PREV 13][GUIDE 13][KEYWORD up-to-13].
    prev = Keyword.get(opts, :prev, "") |> pad_or_trim(13)
    guide = Keyword.get(opts, :guide, "") |> pad_or_trim(13)
    keyword = Keyword.get(opts, :keyword, nil)

    IO.iodata_to_binary([prev, guide, maybe_field(keyword, 13)])
  end

  defp maybe_field(nil, _len), do: <<>>
  defp maybe_field(str, len), do: pad_or_trim(str, len)

  defp pad_or_trim(str, len) do
    cond do
      byte_size(str) >= len -> binary_part(str, 0, len)
      true -> str <> :binary.copy(<<0>>, len - byte_size(str))
    end
  end

  describe "parse/1 - header" do
    test "extracts name, sequence, type, length, version, candidacy" do
      blob = build(name: "TEST       ", sequence: 3, type: 0x08, version: 42, candidacy: 3)

      assert {:ok, %Codec{header: h}} = Codec.parse(blob)
      assert h.name == "TEST       "
      assert h.sequence == 3
      assert h.type == 0x08
      assert h.type_name == :page_element
      assert h.version == 42
      assert h.candidacy == 3
      assert h.candidacy_name == :stage_nov
      assert h.no_version_check? == true
      assert h.length == 18
    end

    test "masks correctly at the 13-bit version ceiling" do
      blob = build(version: 0x1FFF, candidacy: 0x7)
      assert {:ok, %Codec{header: h}} = Codec.parse(blob)
      assert h.version == 8191
      assert h.candidacy == 7
    end

    test "known type codes resolve to names; unknown to nil" do
      for {code, name} <- %{
            0x00 => :page_format,
            0x04 => :page_template,
            0x08 => :page_element,
            0x0C => :program,
            0x0E => :window_element
          } do
        assert {:ok, %Codec{header: %Header{type_name: ^name}}} =
                 Codec.parse(build(type: code))
      end

      assert {:ok, %Codec{header: %Header{type: 0x42, type_name: nil}}} =
               Codec.parse(build(type: 0x42))
    end

    test "all 6 candidacy values resolve to the expected atoms" do
      for {code, name} <- %{
            0 => :cache,
            1 => :none,
            2 => :stage,
            3 => :stage_nov,
            4 => :required,
            5 => :required_nov
          } do
        assert {:ok, %Codec{header: %Header{candidacy_name: ^name}}} =
                 Codec.parse(build(candidacy: code))
      end
    end

    test ":stage_nov and :required_nov both flag no_version_check?" do
      for c <- [3, 5] do
        assert {:ok, %Codec{header: %Header{no_version_check?: true}}} =
                 Codec.parse(build(candidacy: c))
      end

      for c <- [0, 1, 2, 4] do
        assert {:ok, %Codec{header: %Header{no_version_check?: false}}} =
                 Codec.parse(build(candidacy: c))
      end
    end

    test "rejects a blob shorter than the 18-byte header" do
      assert Codec.parse(<<0, 1, 2>>) == {:error, :too_short}
      assert Codec.parse(<<>>) == {:error, :too_short}
    end

    test "rejects a non-UTF8 object name" do
      # 0xC3 alone is an invalid UTF-8 start byte (expects a continuation).
      bad_name = <<0xC3>> <> :binary.copy(<<0>>, 10)
      blob = bad_name <> <<0, 0, 18::16-little, 0, 0, 0>>
      assert Codec.parse(blob) == {:error, :name_not_utf8}
    end
  end

  describe "parse/1 - segments" do
    test "empty body yields no segments" do
      assert {:ok, %Codec{segments: []}} = Codec.parse(build())
    end

    test "recognizes a whitelist of segment types and names them" do
      body =
        frame(0x01, <<1, 2, 3>>) <>
          frame(0x10, <<>>) <>
          frame(0x71, kwnav(keyword: "NEWS")) <>
          frame(0x51, <<0xAB>>)

      assert {:ok, %Codec{segments: segs}} = Codec.parse(build(body: body))
      assert Enum.map(segs, & &1.type_name) == [
               :program_call,
               :header_extension,
               :keyword_navigation,
               :presentation_data
             ]
    end

    test "records payload offsets relative to the start of the blob" do
      body = frame(0x01, <<0xAA, 0xBB>>) <> frame(0x51, <<0xCC>>)
      {:ok, %Codec{segments: [a, b]}} = Codec.parse(build(body: body))

      # Header is 18 bytes; first segment frame starts immediately.
      assert a.offset == 18
      # Second segment starts after first (type + len + 2 bytes payload = 5).
      assert b.offset == 18 + 5
    end

    test "unknown segment type is preserved with nil type_name" do
      body = frame(0x7F, <<0xDE, 0xAD>>)
      assert {:ok, %Codec{segments: [%Segment{type: 0x7F, type_name: nil, payload: <<0xDE, 0xAD>>}]}} =
               Codec.parse(build(body: body))
    end

    test "rejects a segment with length < 3" do
      # Manually craft an invalid frame with length=2.
      bad = <<0x01, 2::16-little>>
      blob = build() |> then(&(&1 <> bad)) |> put_length(18 + byte_size(bad))

      assert {:error, {:bad_segment_length, 2, _}} = Codec.parse(blob)
    end

    test "rejects a segment that claims to extend past the blob" do
      overrun = <<0x01, 1000::16-little, 1, 2, 3>>
      blob = build() |> then(&(&1 <> overrun)) |> put_length(18 + byte_size(overrun))

      assert {:error, {:segment_overruns_blob, 1000, _}} = Codec.parse(blob)
    end

    test "walker stops cleanly on a trailing fragment (< 3 bytes)" do
      body = frame(0x01, <<0xAA>>) <> <<0xFF>>
      assert {:ok, %Codec{segments: [%Segment{type: 0x01}]}} = Codec.parse(build(body: body))
    end

    test "embedded object (0x52) is recursively parsed and attached" do
      inner = build(name: "INNER      ", type: 0x0C, version: 7)
      body = frame(0x52, inner)

      assert {:ok, %Codec{segments: [%Segment{type: 0x52, embedded: %Codec{} = child}]}} =
               Codec.parse(build(type: 0x04, body: body))

      assert child.header.name == "INNER      "
      assert child.header.version == 7
    end
  end

  describe "extract_keyword/1" do
    test "returns :none when there's no 0x71 segment" do
      assert :none = Codec.extract_keyword(parsed!(build()))
    end

    test "returns {:ok, kw} when the 0x71 segment carries a non-empty current keyword" do
      body = frame(0x71, kwnav(keyword: "NEWS"))
      assert {:ok, "NEWS"} = Codec.extract_keyword(parsed!(build(body: body)))
    end

    test "returns :none when the 0x71 payload is missing CURRENT_KEYWORD" do
      # Only PREV_MENU present - no guide or keyword fields.
      body = frame(0x71, pad_or_trim("", 13))
      assert :none = Codec.extract_keyword(parsed!(build(body: body)))
    end

    test "returns :none when the keyword field is all-nulls" do
      body = frame(0x71, kwnav(guide: "", keyword: ""))
      assert :none = Codec.extract_keyword(parsed!(build(body: body)))
    end

    test "stops at the first null byte and strips trailing whitespace" do
      keyword = "MOVIES" <> :binary.copy(<<0>>, 7)
      body = frame(0x71, kwnav(guide: "GUIDE", keyword: keyword))
      assert {:ok, "MOVIES"} = Codec.extract_keyword(parsed!(build(body: body)))
    end

    test "reaches into an embedded object's 0x71 segment" do
      inner_body = frame(0x71, kwnav(keyword: "INNER"))
      inner = build(name: "INNER      ", type: 0x08, body: inner_body)
      outer_body = frame(0x52, inner)

      assert {:ok, "INNER"} = Codec.extract_keyword(parsed!(build(body: outer_body)))
    end
  end

  describe "canonicalize/1 + content_hash/1" do
    test "identical content at different versions hashes the same" do
      a = build(version: 1, body: <<1, 2, 3, 4>>)
      b = build(version: 2, body: <<1, 2, 3, 4>>)
      c = build(version: 8191, body: <<1, 2, 3, 4>>)

      assert Codec.content_hash(a) == Codec.content_hash(b)
      assert Codec.content_hash(a) == Codec.content_hash(c)
    end

    test "different bodies produce different hashes even at same version" do
      a = build(body: <<1, 2, 3>>)
      b = build(body: <<4, 5, 6>>)

      refute Codec.content_hash(a) == Codec.content_hash(b)
    end

    test "candidacy change IS treated as a content change" do
      a = build(candidacy: 0, body: <<1, 2, 3>>)
      b = build(candidacy: 3, body: <<1, 2, 3>>)

      refute Codec.content_hash(a) == Codec.content_hash(b)
    end

    test "canonicalize is a no-op on a blob shorter than the header" do
      short = <<1, 2, 3>>
      assert Codec.canonicalize(short) == short
    end

    test "canonicalize zeros only version bits - other bytes untouched" do
      blob = build(version: 0x1FFF, candidacy: 5, body: <<0xAA, 0xBB>>)
      canon = Codec.canonicalize(blob)

      # First 15 bytes (name + seq + type + length) identical.
      assert binary_part(blob, 0, 15) == binary_part(canon, 0, 15)
      # Byte 15 keeps candidacy (top 3 bits), zeroes version-hi (low 5).
      assert :binary.at(canon, 15) == Bitwise.bsl(5, 5)
      # Byte 16 unchanged (set_size).
      assert :binary.at(blob, 16) == :binary.at(canon, 16)
      # Byte 17 zeroed (version-lo).
      assert :binary.at(canon, 17) == 0
      # Body bytes unchanged.
      assert binary_part(blob, 18, 2) == binary_part(canon, 18, 2)
    end
  end

  describe "build/1" do
    # Captured golden blobs of the Prodigy data-object format that build/1
    # must reproduce byte-for-byte.
    @ref_data_obj Base.decode16!(
                    "3342303030303030442020010C2100200101610F000268656C6C6F20776F726C64",
                    case: :mixed
                  )
    @ref_index_obj Base.decode16!(
                     "3342303030303132532020020C2A0020040761180002000102030405060708090A0B0C0D0E0F10111213",
                     case: :mixed
                   )

    test "matches the golden blob byte-for-byte (data object, defaults)" do
      assert Codec.build(%{name: "3B000000", ext: "D", sequence: 1, data: "hello world"}) ==
               @ref_data_obj
    end

    test "matches the golden blob byte-for-byte (index object, non-default fields)" do
      assert Codec.build(%{
               name: "3B000012",
               ext: "S",
               sequence: 2,
               set_size: 4,
               version: 7,
               data: :binary.list_to_bin(Enum.to_list(0..19))
             }) == @ref_index_obj
    end

    test "round-trips with parse/1: header reflects spec, segment carries 0x02 + data" do
      data = <<1, 2, 3, 0, 255, ?A>>

      blob =
        Codec.build(%{
          name: "MSPLSTAT",
          ext: "D",
          sequence: 1,
          set_size: 3,
          version: 42,
          data: data
        })

      assert {:ok, %Codec{header: h, segments: [seg]}} = Codec.parse(blob)
      assert h.name == "MSPLSTATD  "
      assert h.sequence == 1
      assert h.type == 0x0C
      assert h.set_size == 3
      assert h.candidacy == 1
      assert h.candidacy_name == :none
      assert h.version == 42
      assert h.length == byte_size(blob)
      assert seg.type == 0x61
      assert seg.type_name == :program_data
      assert seg.payload == <<0x02>> <> data
    end

    test "defaults: candidacy 1 (:none), version 1, set_size 1, type 0x0C" do
      assert {:ok, %Codec{header: h}} =
               Codec.build(%{name: "3B000000", ext: "D", sequence: 1, data: ""}) |> Codec.parse()

      assert {h.candidacy, h.version, h.set_size, h.type} == {1, 1, 1, 0x0C}
    end

    test "ext is space-padded to 3 bytes inside the 11-byte header name" do
      blob = Codec.build(%{name: "3L000001", ext: "Y", sequence: 1, data: "x"})
      assert {:ok, %Codec{header: %{name: "3L000001Y  "}}} = Codec.parse(blob)
    end

    test "rejects a name that isn't exactly 8 bytes" do
      assert_raise FunctionClauseError, fn ->
        Codec.build(%{name: "3B", ext: "D", sequence: 1, data: ""})
      end
    end

    test "rejects out-of-range candidacy / version" do
      assert_raise ArgumentError, fn ->
        Codec.build(%{name: "3B000000", ext: "D", sequence: 1, data: "", candidacy: 8})
      end

      assert_raise ArgumentError, fn ->
        Codec.build(%{name: "3B000000", ext: "D", sequence: 1, data: "", version: 0x2000})
      end
    end
  end

  describe "public accessors" do
    test "header_size/0 returns 18" do
      assert Codec.header_size() == 18
    end

    test "max_version/0 returns 8191" do
      assert Codec.max_version() == 0x1FFF
    end

    test "no_version_check?/1 returns true only for 3 and 5" do
      assert Codec.no_version_check?(3)
      assert Codec.no_version_check?(5)
      refute Codec.no_version_check?(0)
      refute Codec.no_version_check?(4)
    end

    test "type_name/1, candidacy_name/1, segment_name/1 round-trip known codes" do
      assert Codec.type_name(0x04) == :page_template
      assert Codec.type_name(0x99) == nil
      assert Codec.candidacy_name(5) == :required_nov
      assert Codec.candidacy_name(9) == nil
      assert Codec.segment_name(0x71) == :keyword_navigation
      assert Codec.segment_name(0x00) == nil
    end
  end

  # -------------------------------------------------------------------

  defp parsed!(blob) do
    {:ok, parsed} = Codec.parse(blob)
    parsed
  end

  # Rewrite the 2-byte length in a blob's header so tests that append
  # extra segment bytes keep the header's `length` consistent - not
  # required for parse (which never reads it back), but lets the fixture
  # stay realistic.
  defp put_length(blob, new_length) do
    <<prefix::binary-size(13), _old_length::16-little, rest::binary>> = blob
    <<prefix::binary, new_length::16-little, rest::binary>>
  end
end
