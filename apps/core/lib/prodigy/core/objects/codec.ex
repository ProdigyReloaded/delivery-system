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

defmodule Prodigy.Core.Objects.Codec do
  @moduledoc """
  Codec for Prodigy Reloaded binary objects:
  an 18-byte header followed by a flat list of segments, each
  framed as `<<type, length::16-little>>` where `length` is the
  frame size including those three bytes.

  Scope: header + segment walker + first-class decoding for
  `0x71 Keyword Navigation` (used to populate the portal's keyword
  index). Other segments come back as raw `{type, payload}`; callers
  that don't need them pay nothing.

  Consumers:

  * `Prodigy.Portal.Admin.Objects` - content-compare + keyword
    extraction on upload. `content_hash/1` drives same-content
    detection, `extract_keyword/1` drives the keyword index.
  * Future admin tooling (object browser, keyword repair) can use
    `parse/1` directly.
  * `ITRC0001.D` Generator
  """

  @header_size 18

  # Object type codes

  @type_page_format 0x00
  @type_page_template 0x04
  @type_page_element 0x08
  @type_program 0x0C
  @type_window_element 0x0E

  @object_type_names %{
    @type_page_format => :page_format,
    @type_page_template => :page_template,
    @type_page_element => :page_element,
    @type_program => :program,
    @type_window_element => :window_element
  }

  # --- Candidacy codes (top 3 bits of the version word) --------------
  #
  # `*_nov` means "NoVersionCheck" - the DOS client skips its usual
  # "server, do I have the latest?" inquiry for these and serves them
  # straight from STAGE.DAT until ITRC0001.D triggers a rescan.

  @candidacy_cache 0
  @candidacy_none 1
  @candidacy_stage 2
  @candidacy_stage_nov 3
  @candidacy_required 4
  @candidacy_required_nov 5

  @candidacy_names %{
    @candidacy_cache => :cache,
    @candidacy_none => :none,
    @candidacy_stage => :stage,
    @candidacy_stage_nov => :stage_nov,
    @candidacy_required => :required,
    @candidacy_required_nov => :required_nov
  }

  @no_version_check_candidacies [@candidacy_stage_nov, @candidacy_required_nov]

  # --- Known segment type codes --------------------------------------

  @segment_keyword_navigation 0x71
  @segment_embedded_object 0x52

  @segment_type_names %{
    0x01 => :program_call,
    0x02 => :field_program_call,
    0x04 => :field_definition,
    0x0A => :custom_text,
    0x0B => :custom_cursor,
    0x0E => :custom_text_ii,
    0x10 => :header_extension,
    0x20 => :page_element_selector,
    0x21 => :page_element_call,
    0x31 => :page_format_call,
    0x33 => :partition_definition,
    0x51 => :presentation_data,
    0x52 => :embedded_object,
    0x61 => :program_data,
    0x62 => :pal_program,
    0x71 => :keyword_navigation
  }

  # Max 13-bit version value (0..8191). Exposed for callers that need
  # to handle the wrap: Prodigy's DOS client tracks versions as 13-bit
  # unsigned; on overflow the server returns 0 and the client sees a
  # "lower" version than its cached copy. Server-side wrap recognition
  # is TODO
  @max_version_value 0x1FFF
  def max_version, do: @max_version_value

  # --- Structs -------------------------------------------------------

  defmodule Header do
    @moduledoc false
    @type t :: %__MODULE__{
            name: String.t(),
            sequence: non_neg_integer(),
            type: non_neg_integer(),
            type_name: atom() | nil,
            length: non_neg_integer(),
            set_size: non_neg_integer(),
            candidacy: non_neg_integer(),
            candidacy_name: atom() | nil,
            no_version_check?: boolean(),
            version: non_neg_integer()
          }

    defstruct [
      :name,
      :sequence,
      :type,
      :type_name,
      :length,
      :set_size,
      :candidacy,
      :candidacy_name,
      :no_version_check?,
      :version
    ]
  end

  defmodule Segment do
    @moduledoc false
    @type t :: %__MODULE__{
            type: non_neg_integer(),
            type_name: atom() | nil,
            payload: binary(),
            offset: non_neg_integer(),
            embedded: Prodigy.Core.Objects.Codec.parsed() | nil
          }

    defstruct [:type, :type_name, :payload, :offset, :embedded]
  end

  @type parsed :: %{
          __struct__: __MODULE__,
          header: Header.t(),
          segments: [Segment.t()],
          raw: binary()
        }

  defstruct header: nil, segments: [], raw: nil

  # --- Public API ----------------------------------------------------

  @doc """
  Parse a Prodigy object blob. Returns `{:ok, %Codec{}}` on success
  or `{:error, reason}` on malformed input.

  `embedded_object` segments (type `0x52`) are recursively parsed; the
  child `%Codec{}` hangs off the parent segment's `:embedded` field so
  callers can walk the whole tree with one pass.
  """
  @spec parse(binary()) :: {:ok, __MODULE__.t()} | {:error, atom()}
  def parse(blob) when is_binary(blob) and byte_size(blob) >= @header_size do
    <<header_bytes::binary-size(@header_size), body::binary>> = blob

    with {:ok, header} <- decode_header(header_bytes),
         {:ok, segments} <- parse_segments(body, @header_size) do
      {:ok, %__MODULE__{header: header, segments: segments, raw: blob}}
    end
  end

  def parse(_), do: {:error, :too_short}

  @doc """
  Header-only parse. Returns `{:ok, %Header{}}` for any blob whose
  first 18 bytes decode cleanly, regardless of whether the body that
  follows is a valid segment stream. Useful for admin upload where we
  want to accept structurally-valid-but-segment-malformed blobs and
  degrade gracefully on keyword extraction.
  """
  @spec parse_header(binary()) :: {:ok, Header.t()} | {:error, atom()}
  def parse_header(blob) when is_binary(blob) and byte_size(blob) >= @header_size do
    <<header_bytes::binary-size(@header_size), _rest::binary>> = blob
    decode_header(header_bytes)
  end

  def parse_header(_), do: {:error, :too_short}

  @type t :: %__MODULE__{
          header: Header.t(),
          segments: [Segment.t()],
          raw: binary()
        }

  @doc """
  Return the first non-empty keyword string declared in a 0x71
  Keyword Navigation segment, or `:none`. Walks embedded objects too
  - a PEO embedded in a PTO that carries a keyword is treated as
  belonging to the parent for index purposes.
  """
  @spec extract_keyword(t()) :: {:ok, String.t()} | :none
  def extract_keyword(%__MODULE__{segments: segments}), do: find_keyword(segments)

  @doc """
  Zero out the 13-bit version field inside the header so two blobs
  that differ only in version number hash identically. Candidacy
  (top 3 bits of byte 15) is preserved - a candidacy change IS a
  content change for our purposes.
  """
  @spec canonicalize(binary()) :: binary()
  def canonicalize(<<pre::binary-size(15), byte15, set_size, _byte17, rest::binary>>) do
    # byte 15: high 3 bits (candidacy) kept, low 5 bits (version hi) zeroed.
    # byte 17: version lo, zeroed entirely.
    <<pre::binary, Bitwise.band(byte15, 0xE0), set_size, 0, rest::binary>>
  end

  def canonicalize(blob) when is_binary(blob), do: blob

  @doc """
  SHA-256 of the canonicalized blob. Same content at different
  versions hashes identically; drives the portal's "no changes"
  detection on re-upload.
  """
  @spec content_hash(binary()) :: binary()
  def content_hash(blob) when is_binary(blob),
    do: :crypto.hash(:sha256, canonicalize(blob))

  @doc "Expose the header size so callers don't hard-code 18."
  def header_size, do: @header_size

  @doc "True when a candidacy code marks the object as NoVersionCheck."
  def no_version_check?(candidacy) when is_integer(candidacy),
    do: candidacy in @no_version_check_candidacies

  @doc "Human-readable name for an object type byte, or nil if unknown."
  def type_name(type) when is_integer(type), do: Map.get(@object_type_names, type)

  @doc "Human-readable name for a candidacy code, or nil if unknown."
  def candidacy_name(c) when is_integer(c), do: Map.get(@candidacy_names, c)

  @doc "Human-readable atom for a segment type byte, or nil if unknown."
  def segment_name(t) when is_integer(t), do: Map.get(@segment_type_names, t)

  # TODO: ITRC0001.D maintenance. When any object with
  # candidacy `:stage_nov` (3) or `:required_nov` (5) is inserted or
  # updated, the reception control object needs to be regenerated so
  # the client knows to run a one-shot version-check pass on its next
  # logon. Payload format is unknown, more research required.

  # --- Header decode -------------------------------------------------

  defp decode_header(
         <<name::binary-size(11), sequence, type, length::16-little, cv_high, set_size, cv_low>>
       ) do
    cond do
      not String.valid?(name) ->
        {:error, :name_not_utf8}

      true ->
        <<candidacy::3, version::13>> = <<cv_high, cv_low>>

        {:ok,
         %Header{
           name: name,
           sequence: sequence,
           type: type,
           type_name: type_name(type),
           length: length,
           set_size: set_size,
           candidacy: candidacy,
           candidacy_name: candidacy_name(candidacy),
           no_version_check?: no_version_check?(candidacy),
           version: version
         }}
    end
  end

  # --- Segment walker ------------------------------------------------

  defp parse_segments(body, base_offset), do: walk_segments(body, base_offset, [])

  defp walk_segments(<<>>, _offset, acc), do: {:ok, Enum.reverse(acc)}

  defp walk_segments(<<leftover::binary>>, _offset, acc) when byte_size(leftover) < 3 do
    {:ok, Enum.reverse(acc)}
  end

  defp walk_segments(<<type, length::16-little, rest::binary>>, offset, acc) do
    cond do
      length < 3 ->
        {:error, {:bad_segment_length, length, offset}}

      length - 3 > byte_size(rest) ->
        {:error, {:segment_overruns_blob, length, offset}}

      true ->
        payload_len = length - 3
        <<payload::binary-size(payload_len), tail::binary>> = rest

        segment = build_segment(type, payload, offset)

        walk_segments(tail, offset + length, [segment | acc])
    end
  end

  defp build_segment(@segment_embedded_object, payload, offset) do
    embedded =
      case parse(payload) do
        {:ok, parsed} -> parsed
        {:error, _} -> nil
      end

    %Segment{
      type: @segment_embedded_object,
      type_name: :embedded_object,
      payload: payload,
      offset: offset,
      embedded: embedded
    }
  end

  defp build_segment(type, payload, offset) do
    %Segment{
      type: type,
      type_name: segment_name(type),
      payload: payload,
      offset: offset,
      embedded: nil
    }
  end

  # --- Keyword lookup ------------------------------------------------

  defp find_keyword([]), do: :none

  defp find_keyword([%Segment{type: @segment_keyword_navigation, payload: payload} | rest]) do
    case decode_keyword_navigation(payload) do
      {:ok, kw} -> {:ok, kw}
      :none -> find_keyword(rest)
    end
  end

  defp find_keyword([%Segment{embedded: %__MODULE__{segments: child}} | rest]) do
    case find_keyword(child) do
      {:ok, _} = found -> found
      :none -> find_keyword(rest)
    end
  end

  defp find_keyword([_ | rest]), do: find_keyword(rest)

  #   bytes 0-12   PREV_MENU        (13 bytes, discarded)
  #   bytes 13-25  GUIDE_BFD        (13 bytes, optional)
  #   bytes 26-38  CURRENT_KEYWORD  (up to 13 ASCII, optional)
  defp decode_keyword_navigation(<<_prev::binary-size(13), rest::binary>>) do
    case rest do
      <<_guide::binary-size(13), keyword_bytes::binary>> ->
        case ascii_at(keyword_bytes, 13) do
          "" -> :none
          kw -> {:ok, kw}
        end

      _ ->
        :none
    end
  end

  defp decode_keyword_navigation(_), do: :none

  # Trim ASCII at the first null or at the specified max length,
  # then strip trailing whitespace
  defp ascii_at(bytes, max_len) do
    take = min(byte_size(bytes), max_len)
    slice = binary_part(bytes, 0, take)

    case :binary.match(slice, <<0>>) do
      :nomatch -> slice |> String.trim_trailing()
      {pos, _} -> slice |> binary_part(0, pos) |> String.trim_trailing()
    end
  end
end
