# Copyright 2022, Phillip Heller
#
# This file is part of prodigyd.
#
# prodigyd is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# prodigyd is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with prodigyd. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Server.Service.Messaging do
  @behaviour Prodigy.Server.Service
  @moduledoc false

  require Logger
  require Ecto.Query
  use EnumType

  import Prodigy.Server.Util

  alias Prodigy.Server.Session
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0, as: Fm0
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Core.Data.{Repo, User, Message}

  def send_message(from_id, from_name, to_ids, _other_ids, subject, body) do
    send_date = DateTime.truncate(Timex.now(), :second)
    expunge_date = Timex.shift(send_date, days: 14)

    Enum.each(to_ids, fn to_id ->
      # TODO also need to Enum.each(to_others, ...
      # TODO extract the logic below into a function
      Repo.transaction(fn ->
        # TODO probably instead just want an primary key that is just an autoincrement index, and
        #    use some pagination or just limit/offset on the view side and leave the maximum number of
        #    messages problem for another day.
        max_index =
          Message
          |> Ecto.Query.where([m], m.to_id == ^to_id)
          |> Ecto.Query.select([m], count(m.index))
          |> Repo.one()

        Repo.insert!(%Message{
          from_id: from_id,
          from_name: from_name |> String.slice(0..17),
          to_id: to_id,
          # TODO handle rolling index over ; e.g., max_index + 1 % 2^16
          index: max_index + 1,
          subject: subject |> String.slice(0..19),
          sent_date: send_date,
          retain_date: expunge_date,
          contents: body,
          retain: false,
          read: false
        })
      end)
    end)

    # TODO if there are delivery failures,
  end

  # TODO there is an issue with replies from mailbox; they seem to be addressed to the from_id of the last item shown on the mailbox page
  defp internal_send_message(
         %User{id: from_id, first_name: first_name, last_name: last_name},
         payload
       ) do
    <<count::16-big, rest::binary>> = payload
    bytes = count * 7
    <<user_ids::binary-size(bytes), rest::binary>> = rest
    to_ids = fixed_chunk(7, user_ids)

    <<others_length::16-big, others::binary-size(others_length), subject_length,
      subject::binary-size(subject_length), message_length::16-big,
      message::binary-size(message_length)>> = rest

    to_others = length_value_chunk(others)

    # TODO need to properly set from_id and from_name
    from_name = "#{first_name} #{last_name}"
    send_message(from_id, from_name, to_ids, to_others, subject, message)
    :ok
  end

  defp get_message(index, to_id) do
    {:ok, message} =
      Repo.transaction(fn ->
        message =
          Message
          |> Ecto.Query.where([m], m.to_id == ^to_id)
          |> Ecto.Query.where([m], m.index == ^index)
          |> Repo.one()

        # TODO update the read flag
        changeset = Message.changeset(message, %{read: true})
        Repo.update(changeset)

        message
      end)

    # TODO rename "contents" to "body"
    length = byte_size(message.contents)

    res = <<
      0::104,
      length::16-big,
      message.contents::binary
    >>

    {:ok, res}
  end

  defp get_mailbox_page(page, user_id) do
    # TODO handle case where page is out of range
    # TODO put these queries in a transaction so that newly arriving mail doesn't mess things up
    # TODO join from_id to user and get the from name, or on send, insert the user's name.  Thinking to not denormalize
    #      this so we can have internet email.

    total_messages =
      Message
      |> Ecto.Query.where([m], m.to_id == ^user_id)
      |> Ecto.Query.select([m], count(m.index))
      |> Repo.one()

    messages =
      Message
      |> Ecto.Query.where([m], m.to_id == ^user_id)
      |> Ecto.Query.order_by([m], desc: m.sent_date)
      |> Ecto.Query.from(limit: 4, offset: (^page - 1) * 4)
      |> Repo.all()

    messages_on_page = length(messages)

    message_payload =
      Enum.reduce(messages, <<>>, fn message, buf ->
        sent_date = Timex.format!(message.sent_date, "{0M}/{0D}")
        retain_date = Timex.format!(message.retain_date, "{0M}/{0D}")
        retain = bool2int(message.retain)
        read = bool2int(message.read)
        from_name_length = String.length(message.from_name)
        subject_length = String.length(message.subject)

        buf <>
          <<
            message.index::16-big,
            message.from_id::binary-size(7),
            # 1 = last message?  (when true, loads MSZC0000.MAP which maybe lacks "next mail") ?
            0::1,
            # 1 = retained, 0 = not retained
            retain::1,
            # ?
            0::1,
            # 1 = read, 0 = unread (show "*")
            read::1,
            # ?
            0x0::4,
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
      |> Ecto.Query.select([m], count(m.index))
      |> Repo.one()

    unread_message_count > 0
  end

  defp handle_message_disposition(payload) do
    <<0x4, delete_count, deletes::binary-size(delete_count), 0x5, retain_count,
      retains::binary-size(retain_count), 0xFF>> = payload

    _delete_indices = fixed_chunk(1, deletes)
    _retain_indices = fixed_chunk(1, retains)

    # TODO the spec shows 1 byte slots, but I think it evolved to two bytes as shown for "index" in the mailbox retrieva
    # TODO no matter, the messaging application doesn't handle this yet anyways.
  end

  # TODO better understand the format of this message
  def handle(%Fm0{payload: <<0x1, payload::binary>>} = request, %Session{} = session) do
    Logger.info("messaging got payload: #{inspect(payload, base: :hex, limit: :infinity)}")

    response =
      case payload do
        # this is sent when jumping to "communication"; this response causes
        # option 2 to read "offline communications", which loads MP000000.PGM (missing)
        # << 0x1e, _rest::binary >> ->                   {:ok, << 0,0,0 >> }

        # this response loads the page as normal, option 2 is "mailbox"
        <<0x1E, _rest::binary>> ->
          {:ok, <<0>>}

        <<0xA, page, _rest::binary>> ->
          get_mailbox_page(page, session.user.id)

        <<0x3, 0x3, index::16-big, 0x1, 0xF4>> ->
          get_message(index, session.user.id)

        <<0x1, 0x2, payload::binary>> ->
          internal_send_message(session.user, payload)

        <<0x4, payload::binary>> ->
          handle_message_disposition(payload)

        _ ->
          Logger.warn(
            "unhandled messaging request: #{inspect(request, base: :hex, limit: :infinity)}"
          )

          {:ok, <<0>>}
      end

    case response do
      {:ok, payload} -> {:ok, session, DiaPacket.encode(Fm0.make_response(payload, request))}
      _ -> {:ok, session}
    end
  end
end
