# Copyright 2022-2026, Phillip Heller
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

defmodule Prodigy.Server.Service.Messaging do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Mailbox Access
  """

  require Logger
  require Ecto.Query
  use EnumType

  import Prodigy.Core.Util

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Message, User}
  alias Prodigy.Core.MessagingLists
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context

  def expunge do
    Logger.debug("Expunging messages ...")

    Repo.transaction(fn ->
      now = DateTime.utc_now()

      {count_read, _} =
        Message
        |> Ecto.Query.where([message], message.read == true)
        |> Ecto.Query.where([message], message.retain_date < ^now)
        |> Repo.delete_all()

      # 3 days old
      oldest_unread_date = DateTime.add(now, 3 * 24 * 60 * 60, :second)

      {count_unread, _} =
        Message
        |> Ecto.Query.where([message], message.read == false)
        |> Ecto.Query.where([message], message.sent_date <= ^oldest_unread_date)
        |> Repo.delete_all()

      total = count_read + count_unread

      Logger.info(
        "Expunged #{count_read} read and #{count_unread} unread messages (#{total} total)"
      )
    end)
  end

  def send_message(from_id, from_name, to_ids, _other_ids, subject, body) do
    send_date = DateTime.truncate(Timex.now(), :second)
    expunge_date = Timex.shift(send_date, days: 14)

    Enum.each(to_ids, fn to_id ->
      Repo.insert!(%Message{
        from_id: from_id,
        from_name: from_name |> String.slice(0..17),
        to_id: to_id,
        subject: subject |> String.slice(0..19),
        sent_date: send_date,
        retain_date: expunge_date,
        contents: body,
        retain: false,
        read: false
      })
    end)
  end

  defp internal_send_message(%User{} = from, payload) do
    <<count::16-big, rest::binary>> = payload
    bytes = count * 7
    <<user_ids::binary-size(bytes), rest::binary>> = rest
    to_ids = fixed_chunk(7, user_ids)

    <<others_length::16-big, others::binary-size(others_length), subject_length,
      subject::binary-size(subject_length), message_length::16-big,
      message::binary-size(message_length)>> = rest

    to_others = length_value_chunk(others)

    # Resolve nicknames + mailing-list names + literal IDs the user typed
    # into the compose page. See MessagingLists.resolve_recipients/2 for
    # the precedence rule (nicknames win over lists; lists expand to
    # member nicknames; literal IDs are User-table-verified).
    {resolved_others, failed_others} =
      MessagingLists.resolve_recipients(from.id, to_others)

    # The fixed 7-char ids the client routed via the multi-recipient
    # to_ids slot need the same existence check; misses join failed_others
    # for the bounce.
    {resolved_fixed, failed_fixed} = verify_fixed_ids(to_ids)

    all_recipients = Enum.uniq(resolved_fixed ++ resolved_others)
    failed = Enum.uniq(failed_fixed ++ failed_others)

    send_message(
      from.id,
      User.full_name(from),
      all_recipients,
      [],
      subject,
      message
    )

    if failed != [] do
      send_bounce(from.id, failed, subject, message)
    end

    :ok
  end

  # Existence check for the fixed 7-char id slots, in one batched query.
  # Empty/blank ids are dropped (the client pads trailing slots with
  # spaces). Misses land in `failed` so the synthesized bounce surfaces
  # them. Returns {existing_ids, missing_ids}, input order preserved.
  defp verify_fixed_ids(ids) do
    trimmed =
      ids
      |> Enum.map(&String.trim(to_string(&1)))
      |> Enum.reject(&(&1 == ""))

    existing =
      Repo.all(
        Ecto.Query.from(u in User, where: u.id in ^Enum.uniq(trimmed), select: u.id)
      )
      |> MapSet.new()

    Enum.split_with(trimmed, &MapSet.member?(existing, &1))
  end

  # Insert a single bounce row in the sender's mailbox. The body is
  # pre-formatted into the wire shape the v2 synth MSZB025X.PGM variant
  # expects, starting at what the client treats as byte 5 (1-indexed) of
  # the message-fetch response:
  #
  #   byte 0    flags - low 7 bits = MSZB0R2S sequence (0x63 = 99 selects
  #             our v2 synth template MSZB0R2S.D99); bit 7
  #             (recipient-count >255 extension) intentionally not set
  #   byte 1    failed-id count (low 8 bits)
  #   bytes 2.. n * 7 fixed-width failed ids (Prodigy-ID-shaped only)
  #   2 bytes   variable-extras length (BE) - additional non-7-char failed
  #             strings packed as <1-byte len><text> entries
  #   M bytes   variable-extras payload
  #   2 bytes   original message body length (BE)   (* v2 wire extension *)
  #   N bytes   original message body              (* v2 wire extension *)
  #
  # get_message/1 prepends the 4-byte response filler (bytes 0..3, unread
  # by MSZB025X) and ships this as the body.
  defp send_bounce(to_id, failed, orig_subject, orig_body) do
    {fixed_ids, variable_extras} = split_failed_for_bounce(failed)

    fixed_bin =
      fixed_ids
      |> Enum.take(255)
      |> Enum.reduce(<<>>, fn id, acc -> acc <> pad_field(id, 7) end)

    variable_bin =
      variable_extras
      |> Enum.reduce(<<>>, fn s, acc ->
        bytes = :erlang.binary_part(s, 0, min(byte_size(s), 255))
        acc <> <<byte_size(bytes)::8, bytes::binary>>
      end)

    send_date = DateTime.truncate(Timex.now(), :second)
    expunge_date = Timex.shift(send_date, days: 14)

    # Prefix the original body with Subject + Sent-on metadata. The
    # MSZB0R2S.D99 template footer ends after "...can get messages.";
    # this prefix gives the bounce display its dynamic per-message
    # lines (40-col padded for column alignment) before the actual
    # body bytes flow into the page. Subject is truncated to match
    # the 0..19 slice send_message/6 uses when storing delivered
    # rows; date renders in US/Eastern per the codebase convention
    # established in Service.Logoff.
    truncated_subject = orig_subject |> to_string() |> String.slice(0..19)

    date_str =
      send_date
      |> Timex.Timezone.convert("US/Eastern")
      |> Timex.format!("{0M}/{0D}/{YY} {0h12}:{0m} {AM}")

    blank_line = :binary.copy(" ", 40)
    subject_line = pad_field("Subject: #{truncated_subject}", 40)
    date_line = pad_field("Sent on: #{date_str}", 40)

    body_with_meta =
      blank_line <> subject_line <> date_line <> blank_line <> orig_body

    payload =
      <<
        0x63,
        length(fixed_ids)::8,
        fixed_bin::binary,
        byte_size(variable_bin)::16-big,
        variable_bin::binary,
        byte_size(body_with_meta)::16-big,
        body_with_meta::binary
      >>

    Repo.insert!(%Message{
      from_id: "HELP99A",
      from_name: "PRODIGY SERVICE",
      to_id: to_id,
      subject: "Return To Sender",
      sent_date: send_date,
      retain_date: expunge_date,
      contents: payload,
      retain: false,
      read: false,
      bounce: true
    })

    :ok
  end

  # Failed recipients shaped like a Prodigy ID (7 chars, exactly 4 alpha +
  # 2 digit + 1 hex alpha) go in the fixed-width list; everything else
  # (nicknames, list names the user typoed, free-form garbage) lands in
  # the variable-extras list so MSZB025X displays them with full text.
  @prodigy_id_regex ~r/^[A-Za-z]{4}\d{2}[A-Fa-f]$/
  defp split_failed_for_bounce(failed) do
    Enum.split_with(failed, fn s -> Regex.match?(@prodigy_id_regex, s) end)
  end

  defp load_message_ids(user_id) do
    Message
    |> Ecto.Query.where([m], m.to_id == ^user_id)
    |> Ecto.Query.order_by([m], [desc: m.sent_date, desc: m.id ])
    |> Ecto.Query.select([m], m.id)
    |> Ecto.Query.limit(252)
    |> Repo.all()
  end

  defp get_message(client_index, context) do
    # Client index is 1-based, Elixir lists are 0-based
    message_id = Enum.at(context.messaging.message_ids, client_index)

    if message_id do
      {:ok, message} =
        Repo.transaction(fn ->
          # Verify the message belongs to the current user
          message =
            Message
            |> Ecto.Query.where([m], m.id == ^message_id)
            |> Ecto.Query.where([m], m.to_id == ^context.user.id)
            |> Repo.one()

          if message do
            changeset = Message.changeset(message, %{read: true})
            {:ok, updated} = Repo.update(changeset)
            updated
          else
            nil
          end
        end)

      if message do
        res =
          if message.bounce do
            # Bounce body wire format expected by MSZB025X.PGM. The first
            # 4 bytes are filler (unread by the parser); message.contents
            # already starts at what MSZB025X treats as byte 5 (1-indexed)
            # of the response - see send_bounce/4 for the layout.
            <<0::32, message.contents::binary>>
          else
            length = byte_size(message.contents)

            <<
              0::104,
              length::16-big,
              message.contents::binary
            >>
          end

        {:ok, res}
      else
        Logger.error("Message #{message_id} not found or unauthorized for user #{context.user.id}")
        {:error, "Message not found"}
      end
    else
      Logger.error("Invalid message index: #{client_index}")
      {:error, "Message not found"}
    end
  end

  defp get_mailbox_page(page, context) do
    message_ids = context.messaging.message_ids
    total_messages = length(message_ids)

    # Calculate which message IDs are on this page (4 messages per page)
    offset = (page - 1) * 4
    page_message_ids = Enum.slice(message_ids, offset, 4)

    messages = if length(page_message_ids) > 0 do
      # Fetch messages without ordering
      messages_map =
        Message
        |> Ecto.Query.where([m], m.id in ^page_message_ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})

      # Return them in the exact order from page_message_ids
      page_message_ids
      |> Enum.map(&Map.get(messages_map, &1))
      |> Enum.filter(&(&1 != nil))
    else
      []
    end

    messages_on_page = length(messages)

    message_payload =
      messages
      |> Enum.with_index(offset)  # Calculate client index starting from offset
      |> Enum.reduce(<<>>, fn {message, client_index}, buf ->
        sent_date = Timex.format!(message.sent_date, "{0M}/{0D}")
        retain_date = Timex.format!(message.retain_date, "{0M}/{0D}")
        retain = bool2int(message.retain)
        read = bool2int(message.read)
        # MSZB016X.src line 141 reads msg_flags1 & 0x04 as the
        # return-to-sender bit; when set the inbox display LINKs to
        # MSZB025X.PGM (bounce parser). Bit at position 2 of the low
        # nibble below.
        bounce_bit = bool2int(message.bounce)
        from_name_length = String.length(message.from_name)
        subject_length = String.length(message.subject)

        buf <>
        <<
          client_index::16-big,  # Use calculated client index
          message.from_id::binary-size(7),
          # 1 = last message?  (when true, loads MSZC0000.MAP which maybe lacks "next mail") ?
          0::1,
          # 1 = retained, 0 = not retained
          retain::1,
          # ?
          0::1,
          # 1 = read, 0 = unread (show "*")
          read::1,
          # bit 3 (0x08): unused
          0::1,
          # bit 2 (0x04): return-to-sender (bounce)
          bounce_bit::1,
          # bits 1-0: unused
          0::2,
          # 2nd flag byte - one of these indicates another field follows the subject, I think
          0,
          sent_date::binary-size(5),
          retain_date::binary-size(5),
          from_name_length,
          message.from_name::binary-size(from_name_length),
          subject_length,
          message.subject::binary-size(subject_length)
        >>
      end)

    {:ok, <<total_messages::16-big, messages_on_page, message_payload::binary>>}
  end

  def unread_messages?(user) do
    unread_message_count =
      Message
      |> Ecto.Query.where([m], m.to_id == ^user.id)
      |> Ecto.Query.where([m], m.read == false)
      |> Ecto.Query.select([m], count(m.id))
      |> Repo.one()

    unread_message_count > 0
  end

  defp do_disposition(<< 0x4, count::16-big, rest::binary >>, context) do
    byte_count = count * 2
    << data::binary-size(byte_count), rest::binary >> = rest

    client_indices = for << index::16-big <- data >>, do: index

    # Map client indices to message IDs
    message_ids_to_delete = client_indices
    |> Enum.map(fn idx -> Enum.at(context.messaging.message_ids, idx) end)
    |> Enum.filter(&(&1 != nil))

    Logger.debug("delete message indices: #{inspect message_ids_to_delete}")

    {:ok, _message} =
      Repo.transaction(fn ->
        Message
        |> Ecto.Query.where([m], m.to_id == ^context.user.id)
        |> Ecto.Query.where([m], m.id in ^message_ids_to_delete)
        |> Repo.delete_all()
      end)

    # explicitly don't mutate the context message_ids because we might have more references that
    # are to it as is.  Also, we only call dispose when we are leaving messaging.  Guarantee to
    # have a get_message_page(1) call if client comes back, which will refresh context

    do_disposition(rest, context)
  end

  defp do_disposition(<< 0x5, count::16-big, rest::binary >>, context) do
    byte_count = count * 2
    << data::binary-size(byte_count), rest::binary >> = rest

    client_indices = for << index::16-big <- data >>, do: index

    # Map client indices to message IDs
    message_ids_to_retain = client_indices
    |> Enum.map(fn idx -> Enum.at(context.messaging.message_ids, idx) end)
    |> Enum.filter(&(&1 != nil))

    Logger.debug("retain message indices: #{inspect message_ids_to_retain}")

    Repo.transaction(fn ->
      messages = Message
      |> Ecto.Query.where([m], m.to_id == ^context.user.id)
      |> Ecto.Query.where([m], m.id in ^message_ids_to_retain)
      |> Ecto.Query.where([m], m.retain == false)
      |> Repo.all()

      Enum.each(messages, fn message ->
        # set the retain date
        retain_date = DateTime.add(message.sent_date, 28 * 24 * 60 * 60, :second)

        changeset = Message.changeset(message, %{retain: true, retain_date: retain_date})
        Repo.update(changeset)
      end)
    end)

    do_disposition(rest, context)
  end

  defp do_disposition(<< 0xff >>, context) do
    # done
    Logger.debug("done processing dispositions")
    context
  end

  # MSZX0BIP "message count" query reached from compose OPTIONS -> Count.
  # Wire format (5 bytes): <<0x11, 0x01, 0x01, 0x00, month::8>>.
  #
  # The 1990 MSZX011X.WND has only two display fields - &10 (header
  # suffix) and &11 (count text) - so the response shape is
  # correspondingly simple (matches the v2 synth MSZX011A.src):
  #
  #   bytes 0-8     9-char month label                     -> &10
  #   bytes 9-29    21-char total-sent count, left-padded  -> &11
  #
  # Count = total personal messages sent by all members of the
  # household this month, with bounces excluded.  (HELP99A is the
  # only from_id used for bounces and isn't a household member id,
  # but explicit exclusion is robust.)
  def handle(%Fm0{payload: <<0x11, 0x01, 0x01, 0x00, month_byte>>} = request, %Context{} = context) do
    payload = build_message_count_response(context.user, month_byte)
    {:ok, context, DiaPacket.encode(Fm0.make_response(payload, request))}
  end

  def handle(%Fm0{payload: <<0x1, payload::binary>>} = request, %Context{} = context) do
    Logger.debug("messaging got payload: #{inspect(payload, base: :hex, limit: :infinity)}")

    {context, response} =
      case payload do
        # this is sent when jumping to "communication"; this response causes
        # option 2 to read "offline communications", which loads MP000000.PGM (missing)
        # << 0x1e, _rest::binary >> ->                   {:ok, << 0,0,0 >> }

        # this response loads the page as normal, option 2 is "mailbox"
        <<0x1E, _rest::binary>> ->
          {context, {:ok, <<0>>}}

        # Mailbox page request - check if we need to load message IDs
        <<0xA, page, _rest::binary>> ->
          context = if page == 1 or not Map.has_key?(context, :messaging) or is_nil(context.messaging) do
            message_ids = load_message_ids(context.user.id)
            Map.put(context, :messaging, %{message_ids: message_ids})
          else
            context
          end

          {context, get_mailbox_page(page, context)}

        <<0x3, 0x3, index::16-big, 0x1, 0xF4>> ->
          {context, get_message(index, context)}

        <<0x1, 0x2, payload::binary>> ->
          {context, internal_send_message(context.user, payload)}

          # Request for next message within full message view
        <<0x3, index::16-big>> ->
          {context, get_message(index, context)}

        # Body-continuation request. The RS 6.x client's MSZB016X always
        # sets &192=1 and sends <<0x0b, msg_index::16-big>> whenever the
        # first-response body length is exactly 500 bytes; it then
        # appends whatever the continuation returns. We never split
        # bodies (messages flow end-to-end in the 0x0303 response), so a
        # zero-length continuation is the graceful no-op the client
        # needs. Without this handler, every 500-byte message would
        # time out the reader with a "messaging down" error window.
        <<0xB, _index::16-big>> ->
          {context, {:ok, <<0::16>>}}

        <<0x4, _rest::binary>> ->
          {do_disposition(payload, context), :ok} # deletes

        <<0x5, _rest::binary>> ->
          {do_disposition(payload, context), :ok} # retains

        _ ->
          Logger.warning(
            "unhandled messaging request: #{inspect(request, base: :hex, limit: :infinity)}"
          )

          {context, :ok, <<0>>}
      end

    case response do
      {:ok, payload} -> {:ok, context, DiaPacket.encode(Fm0.make_response(payload, request))}
      _ -> {:ok, context}
    end
  end

  # Build the 30-byte response MSZX011A.src expects (v2 synth).
  # See the handle/2 clause above for the wire-format spec.
  defp build_message_count_response(%User{household_id: household_id}, month_byte) do
    {year, month} = resolve_year_and_month(month_byte)
    {first_dt, next_first_dt} = month_bounds(year, month)

    # Up to 6 household members - join over user.id since Message.from_id
    # carries the per-user id, not the household id.
    member_ids =
      User
      |> Ecto.Query.where([u], u.household_id == ^household_id)
      |> Ecto.Query.select([u], u.id)
      |> Repo.all()

    total_sent =
      Message
      |> Ecto.Query.where([m], m.from_id in ^member_ids)
      |> Ecto.Query.where([m], m.bounce == false)
      |> Ecto.Query.where([m], m.sent_date >= ^first_dt and m.sent_date < ^next_first_dt)
      |> Repo.aggregate(:count, :id)

    month_label = format_month_label(year, month)
    count_text = pad_field(Integer.to_string(total_sent), 21)

    <<month_label::binary-size(9), count_text::binary-size(21)>>
  end

  # Month byte comes from MSZX0BIP via SYS_DATE; year is the current
  # year in US/Eastern (same convention as Logoff and the bounce
  # "Sent on:" line).
  defp resolve_year_and_month(month_byte) do
    eastern_now = Timex.now() |> Timex.Timezone.convert("US/Eastern")
    {eastern_now.year, month_byte}
  end

  defp month_bounds(year, month) do
    {:ok, first_date} = Date.new(year, month, 1)
    first_dt = DateTime.new!(first_date, ~T[00:00:00], "Etc/UTC")

    next_first_date =
      case month do
        12 -> Date.new!(year + 1, 1, 1)
        _ -> Date.new!(year, month + 1, 1)
      end

    next_first_dt = DateTime.new!(next_first_date, ~T[00:00:00], "Etc/UTC")
    {first_dt, next_first_dt}
  end

  # Render " MMM YYYY" (9 chars) for the &10 field.
  defp format_month_label(year, month) do
    name =
      case month do
        1 -> "JAN"
        2 -> "FEB"
        3 -> "MAR"
        4 -> "APR"
        5 -> "MAY"
        6 -> "JUN"
        7 -> "JUL"
        8 -> "AUG"
        9 -> "SEP"
        10 -> "OCT"
        11 -> "NOV"
        12 -> "DEC"
        _ -> "???"
      end

    " #{name} #{year}"
  end

  # Left-align text, right-pad with spaces to width; truncate if too long.
  defp pad_field(text, width) when is_binary(text) do
    case byte_size(text) do
      n when n >= width -> :erlang.binary_part(text, 0, width)
      n -> text <> :binary.copy(" ", width - n)
    end
  end
end
