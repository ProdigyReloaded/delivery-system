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

defmodule Prodigy.Core.Objects.KeywordIndex do
  @moduledoc """
  Codec for the Prodigy keyword-navigation index - the primary object
  (`TAODCUSSPGM`) plus its fan-out of secondaries (`TAODCUKJD  `, seq
  1..N). These are the objects the DOS client's jumpword window
  ultimately fetches: the user types `FOO`, `XXPXJMPP` hands off to
  `XXPXKWRD`, which walks the primary's boundary list to pick the
  right secondary, then scans the secondary's prefix-compressed entry
  list for the exact keyword and its target object id.

  ## On-disk layout (both primary and secondaries)

  Standard 18-byte Prodigy object header, then a PROGRAM_DATA (0x61)
  segment wrapping the actual keyword data. All offsets below are
  0-based inside the segment payload (TBOL's `SUBSTR` is 0-based; this
  bit ate a lot of debugging until the `SUBSTR KEYWORD_TABLE, P3,
  '2', '9'` in `XXPXKWRD` was read as "9 bytes starting at offset 2"
  and produced the expected stem `TAODCUKJD`).

  ### Primary payload

      offset  bytes  field                        notes
      0       1      format_flag                  0x02 in all four real samples
      1       1      keywords_per_secondary       0x0E (14) observed
      2..12   11     secondary_name_template      "TAODCUKJD  " - first 9 bytes are
                                                  the name stem used by proc_1
      13      1      first_seq_byte               0x01 - Nth secondary seq =
                                                  first_seq + (N - 1)
      14      1      type_byte                    0x0C (Program)
      15      1      total_secondaries            Actual count of secondaries.
                                                  XXPXKWRD label_358/373 uses
                                                  this as a circular-iteration
                                                  wrap point (`IF I4 < I5 THEN
                                                  MOVE '1', I5`). Setting it
                                                  higher than the number of
                                                  secondaries we actually write
                                                  makes the "Index" listing
                                                  walk past the last real seq
                                                  and FETCH a missing object.
                                                  Live-client confirmed
                                                  2026-04-19.
      16..    var    boundary_keywords            repeating (u8 length, N-byte
                                                  keyword), one per secondary.
                                                  Each is the LAST keyword in
                                                  that secondary.

  ### Secondary payload

      offset  bytes  field                        notes
      0       1      format_flag                  0x02 (same as primary)
      1       1      keyword_count                u8; entries in this secondary
      2..     var    entries                      see below

  ### Keyword entry (variable length)

      offset  bytes  field                        notes
      0       1      prefix_length                chars to carry forward from
                                                  the previous reconstructed
                                                  keyword (0 for the first entry)
      1       1      suffix_length                byte count of the suffix
      2       N      suffix                       suffix_length bytes
      2+N     11     target object name           space-padded to 11 bytes
      13+N    1      target sequence
      14+N    1      target type

  Reconstruction (`XXPXKWRD label_233`, the `STRING P7, P6, P8` line):

      new_keyword = binary_part(previous_keyword, 0, prefix_length) <> suffix

  `prefix_length = 0` with the full keyword in the suffix is valid and
  is what our dev seed emitted before compression was wired in;
  production compresses aggressively (see the seq-53 sample:
  MAGID->MAIL->MAILBOX->MAILING LIST encodes as prefix-share 0,2,4,4).
  """

  alias Prodigy.Core.Objects.Codec

  @program_data_segment 0x61

  # --- structs -------------------------------------------------------

  defmodule Primary do
    @moduledoc """
    Decoded primary keyword-index object. Carries the metadata needed
    to build secondary object IDs (`proc_1` in `XXPXKWRD`) and the
    boundary-keyword list that `XXPXKWRD label_?` binary-searches to
    pick which secondary to load.
    """

    @type t :: %__MODULE__{
            format_flag: byte(),
            keywords_per_secondary: non_neg_integer(),
            secondary_name_template: binary(),
            first_seq_byte: byte(),
            secondary_type: byte(),
            total_secondaries: non_neg_integer(),
            boundary_keywords: [String.t()],
            version: non_neg_integer(),
            candidacy: byte()
          }

    defstruct [
      :format_flag,
      :keywords_per_secondary,
      :secondary_name_template,
      :first_seq_byte,
      :secondary_type,
      :total_secondaries,
      :boundary_keywords,
      :version,
      :candidacy
    ]
  end

  defmodule Entry do
    @moduledoc "One keyword -> target-object mapping inside a secondary."

    @type t :: %__MODULE__{
            keyword: String.t(),
            prefix_length: non_neg_integer(),
            target_name: binary(),
            target_sequence: byte(),
            target_type: byte()
          }

    defstruct [:keyword, :prefix_length, :target_name, :target_sequence, :target_type]
  end

  defmodule Secondary do
    @moduledoc """
    Decoded secondary keyword-index object. Carries its own header
    metadata + the list of reconstructed (uncompressed) keyword
    entries. Re-encoding uses the preserved `prefix_length` on each
    entry so round-trips exactly reproduce the on-disk compression.

    The `name` field is the 11-byte object name (space-padded) so the
    encoder can emit the same header on round-trip without the caller
    having to pass it separately.
    """

    @type t :: %__MODULE__{
            name: binary(),
            format_flag: byte(),
            sequence: byte(),
            entries: [Entry.t()],
            version: non_neg_integer(),
            candidacy: byte()
          }

    defstruct [:name, :format_flag, :sequence, :entries, :version, :candidacy]
  end

  # --- public API ----------------------------------------------------

  @doc """
  Decode a full keyword-index primary object blob (header + segment +
  payload). Returns `{:ok, %Primary{}}` or `{:error, reason}`.
  """
  @spec decode_primary(binary()) :: {:ok, Primary.t()} | {:error, atom()}
  def decode_primary(blob) when is_binary(blob) do
    with {:ok, payload, header} <- extract_segment_payload(blob),
         {:ok, primary} <- parse_primary_payload(payload, header) do
      {:ok, primary}
    end
  end

  @doc """
  Decode a full keyword-index secondary object blob. Returns
  `{:ok, %Secondary{}}` or `{:error, reason}`.
  """
  @spec decode_secondary(binary()) :: {:ok, Secondary.t()} | {:error, atom()}
  def decode_secondary(blob) when is_binary(blob) do
    with {:ok, payload, header} <- extract_segment_payload(blob),
         {:ok, secondary} <- parse_secondary_payload(payload, header) do
      {:ok, secondary}
    end
  end

  # --- shared header + segment extraction ----------------------------

  # Pull the Prodigy header, then the single PROGRAM_DATA segment's
  # payload. Every real-world keyword-index file has exactly one
  # segment (type 0x61); anything else is an error.
  defp extract_segment_payload(blob) do
    with {:ok, header} <- Codec.parse_header(blob),
         {:ok, segment_payload} <- take_program_data_segment(blob) do
      {:ok, segment_payload, header}
    end
  end

  defp take_program_data_segment(blob) do
    header_size = Codec.header_size()

    case blob do
      <<_header::binary-size(header_size), @program_data_segment, length::16-little,
        rest::binary>>
      when length >= 3 ->
        payload_size = length - 3

        case rest do
          <<payload::binary-size(payload_size), _tail::binary>> ->
            {:ok, payload}

          _ ->
            {:error, :segment_truncated}
        end

      <<_header::binary-size(header_size), other, _::binary>> ->
        {:error, {:unexpected_segment_type, other}}

      _ ->
        {:error, :no_segment}
    end
  end

  # --- primary parse -------------------------------------------------

  # Payload layout (0-based offsets per XXPXKWRD's SUBSTR reads):
  #   0      format_flag
  #   1      keywords_per_secondary
  #   2..12  secondary_name_template (11 bytes)
  #   13     first_seq_byte
  #   14     secondary_type
  #   15     total_secondaries  (XXPXKWRD label_358/373 wraps on it)
  #   16..   boundary_keywords (u8 len, N bytes keyword) x one per secondary
  defp parse_primary_payload(
         <<format_flag, kw_per_sec, template::binary-size(11), first_seq, type_byte,
           total_secondaries, rest::binary>>,
         header
       ) do
    with {:ok, boundary_keywords} <- parse_length_prefixed_list(rest) do
      {:ok,
       %Primary{
         format_flag: format_flag,
         keywords_per_secondary: kw_per_sec,
         secondary_name_template: template,
         first_seq_byte: first_seq,
         secondary_type: type_byte,
         total_secondaries: total_secondaries,
         boundary_keywords: boundary_keywords,
         version: header.version,
         candidacy: header.candidacy
       }}
    end
  end

  defp parse_primary_payload(_, _), do: {:error, :primary_payload_too_short}

  # Repeating (u8 length)(N-byte string). No terminator - consumes to
  # end-of-buffer. Each slot is one secondary's last keyword.
  defp parse_length_prefixed_list(binary), do: parse_length_prefixed_list(binary, [])

  defp parse_length_prefixed_list(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_length_prefixed_list(<<len, rest::binary>>, acc) when byte_size(rest) >= len do
    <<kw::binary-size(len), tail::binary>> = rest
    parse_length_prefixed_list(tail, [kw | acc])
  end

  defp parse_length_prefixed_list(_, _), do: {:error, :truncated_boundary_list}

  # --- secondary parse -----------------------------------------------

  # Payload layout:
  #   0      format_flag (same 0x02 constant as the primary)
  #   1      keyword_count  (u8; matches length of entries)
  #   2..    entries, each:
  #            u8 prefix_length
  #            u8 suffix_length
  #            N  suffix bytes
  #            11 target_name (space-padded)
  #            u8 target_sequence
  #            u8 target_type
  defp parse_secondary_payload(<<format_flag, kw_count, body::binary>>, header) do
    case parse_entries(body, kw_count, nil, []) do
      {:ok, entries} ->
        {:ok,
         %Secondary{
           name: header.name,
           format_flag: format_flag,
           sequence: header.sequence,
           entries: entries,
           version: header.version,
           candidacy: header.candidacy
         }}

      {:error, _} = err ->
        err
    end
  end

  defp parse_secondary_payload(_, _), do: {:error, :secondary_payload_too_short}

  defp parse_entries(_rest, 0, _prev, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_entries(
         <<prefix_len, suffix_len, rest::binary>>,
         remaining,
         prev,
         acc
       )
       when byte_size(rest) >= suffix_len + 13 do
    <<suffix::binary-size(suffix_len), target_name::binary-size(11), target_seq, target_type,
      tail::binary>> = rest

    with {:ok, reconstructed} <- reconstruct_keyword(prev, prefix_len, suffix) do
      entry = %Entry{
        keyword: reconstructed,
        prefix_length: prefix_len,
        target_name: target_name,
        target_sequence: target_seq,
        target_type: target_type
      }

      parse_entries(tail, remaining - 1, reconstructed, [entry | acc])
    end
  end

  defp parse_entries(_, _, _, _), do: {:error, :entry_truncated}

  # XXPXKWRD label_233: the reconstruction is literally
  #   new_keyword = previous_keyword[0..prefix_length-1] <> suffix
  # The first entry in a secondary has prefix_length = 0, so `prev` is
  # allowed to be nil on that first call.
  defp reconstruct_keyword(nil, 0, suffix), do: {:ok, suffix}
  defp reconstruct_keyword(nil, _n, _suffix), do: {:error, :prefix_on_first_entry}

  defp reconstruct_keyword(prev, prefix_len, suffix) when prefix_len <= byte_size(prev) do
    {:ok, binary_part(prev, 0, prefix_len) <> suffix}
  end

  defp reconstruct_keyword(_, _, _), do: {:error, :prefix_exceeds_previous}

  # --- PROGRAM_DATA segment type (exposed for the encoder + tests) ---

  @doc false
  def program_data_segment_type, do: @program_data_segment

  # --- encoder -------------------------------------------------------

  @primary_name "TAODCUSSPGM"
  @primary_sequence 0

  @doc """
  Emit a full primary-object blob (header + PROGRAM_DATA segment)
  from a `%Primary{}` struct. Round-trips with `decode_primary/1` -
  `encode_primary(decode_primary!(bytes)) == bytes` is a test
  invariant against the golden fixtures.
  """
  @spec encode_primary(Primary.t()) :: binary()
  def encode_primary(%Primary{} = p) do
    payload =
      <<p.format_flag, p.keywords_per_secondary, p.secondary_name_template::binary-size(11),
        p.first_seq_byte, p.secondary_type, p.total_secondaries>> <>
        encode_length_prefixed_list(p.boundary_keywords)

    wrap_in_object(@primary_name, @primary_sequence, 0x0C, p.version, p.candidacy, payload)
  end

  @doc """
  Emit a full secondary-object blob from a `%Secondary{}` struct.
  Uses each `%Entry{}`'s stored `prefix_length` verbatim so a
  decode+encode cycle reproduces the original bytes exactly.
  """
  @spec encode_secondary(Secondary.t()) :: binary()
  def encode_secondary(%Secondary{} = s) do
    entries_blob =
      s.entries
      |> Enum.map(&encode_entry/1)
      |> IO.iodata_to_binary()

    payload = <<s.format_flag, length(s.entries)>> <> entries_blob

    wrap_in_object(s.name, s.sequence, 0x0C, s.version, s.candidacy, payload)
  end

  @doc """
  Build a `%Secondary{}` from a flat list of `{keyword, target_ref}`
  tuples, computing prefix compression against each pair of adjacent
  keywords. `target_ref` is `{target_name (11 bytes), target_seq,
  target_type}`. The list is expected to be alphabetically sorted -
  we don't resort, so the caller owns that.

  Options: `:sequence` (required), `:name` (11-byte name, defaults to
  `"TAODCUKJD  "`), `:version`, `:candidacy`, `:format_flag`.
  """
  @spec build_secondary([{String.t(), {binary(), byte(), byte()}}], keyword()) :: Secondary.t()
  def build_secondary(entries, opts \\ []) when is_list(entries) do
    sequence = Elixir.Keyword.fetch!(opts, :sequence)
    name = Elixir.Keyword.get(opts, :name, "TAODCUKJD  ")

    built =
      entries
      |> Enum.map_reduce(nil, fn {keyword, {target_name, t_seq, t_type}}, prev ->
        prefix_len = longest_common_prefix_length(prev, keyword)

        entry = %Entry{
          keyword: keyword,
          prefix_length: prefix_len,
          target_name: target_name,
          target_sequence: t_seq,
          target_type: t_type
        }

        {entry, keyword}
      end)
      |> elem(0)

    %Secondary{
      name: name,
      format_flag: Elixir.Keyword.get(opts, :format_flag, 0x02),
      sequence: sequence,
      entries: built,
      version: Elixir.Keyword.get(opts, :version, 1),
      candidacy: Elixir.Keyword.get(opts, :candidacy, 0)
    }
  end

  # --- encoder helpers -----------------------------------------------

  defp encode_entry(%Entry{} = e) do
    suffix = keyword_suffix(e)

    <<e.prefix_length, byte_size(suffix), suffix::binary, e.target_name::binary-size(11),
      e.target_sequence, e.target_type>>
  end

  # The suffix actually written to the wire: bytes of the full
  # reconstructed keyword past the shared prefix. If the decoder saw
  # "MAILBOX" with prefix_length=4 it stored the full "MAILBOX"; on
  # re-encode we emit only "BOX".
  defp keyword_suffix(%Entry{keyword: kw, prefix_length: prefix_len}) do
    binary_part(kw, prefix_len, byte_size(kw) - prefix_len)
  end

  defp encode_length_prefixed_list(list) do
    list
    |> Enum.map(fn s -> <<byte_size(s), s::binary>> end)
    |> IO.iodata_to_binary()
  end

  # Re-wrap a payload into a PROGRAM_DATA segment inside a Prodigy
  # object header. Mirror of Codec.parse_header: cv_high carries the
  # candidacy in the top 3 bits + version bits 12..8, cv_low is
  # version bits 7..0. set_size is left at 0 across all four real
  # samples.
  defp wrap_in_object(name, sequence, type, version, candidacy, payload) do
    segment_length = 3 + byte_size(payload)
    segment = <<@program_data_segment, segment_length::16-little, payload::binary>>

    total_length = 18 + byte_size(segment)

    version_hi = Bitwise.bsr(version, 8) |> Bitwise.band(0x1F)
    version_lo = Bitwise.band(version, 0xFF)
    cv_high = Bitwise.bor(Bitwise.bsl(candidacy, 5), version_hi)

    header =
      <<name::binary-size(11), sequence, type, total_length::16-little, cv_high, 0, version_lo>>

    header <> segment
  end

  # Returns the number of leading bytes `a` and `b` share. Bounded by
  # `byte_size(a)` so an entry-pair where `b` is longer still only
  # reuses up to all of `a`.
  defp longest_common_prefix_length(nil, _b), do: 0

  defp longest_common_prefix_length(a, b) when is_binary(a) and is_binary(b) do
    max_shared = min(byte_size(a), byte_size(b))
    do_lcp(a, b, 0, max_shared)
  end

  defp do_lcp(_a, _b, n, n), do: n

  defp do_lcp(a, b, n, max) do
    if :binary.at(a, n) == :binary.at(b, n) do
      do_lcp(a, b, n + 1, max)
    else
      n
    end
  end
end
