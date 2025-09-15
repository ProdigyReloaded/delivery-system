# Copyright 2022-2025, Phillip Heller
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

defmodule Prodigy.Server.Service.BulletinBoards do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Bulletin Board Requests
  """

  import Ecto.Query

  require Logger

  alias Prodigy.Core.Data.{Club, Post, Repo, Topic, User, UserClub}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context

  def handle(%Fm0{payload: <<0x3, payload::binary>>} = request, %Context{} = context) do
    {context, response} = case payload do
      # Enter club
      <<0, 0, 0x65, club_handle::bytes-size(3)>> ->
        handle_enter_club(club_handle, context)

      # List topics for club
      <<0, 0, 0xF, club_handle::bytes-size(3), 0xC>> ->
        handle_list_topics(club_handle, context)

      # Start cursor for notes since date/time
      <<0, 0, 0x67, 0x24, mon::bytes-size(2), day::bytes-size(2), min::bytes-size(2),
        hour::bytes-size(2), topic_id::16-big>> ->
        handle_start_note_cursor(mon, day, min, hour, topic_id, context)

      # note cursor page selection
      <<0, 0, 0x67, 8, page_no::16-big, _mon::bytes-size(2), _day::bytes-size(2), _rest::binary >> ->
        handle_select_note_cursor_page(page_no, context)

      # Navigate note headers
      <<0, 0, 0x67, direction, _mon::bytes-size(2), _day::bytes-size(2),
        topic_len::16-big, _topic_text::binary-size(topic_len)>> ->
        handle_navigate_note_cursor(direction, context)

      # Get note header and first page
      <<0, 0, 0x68, 0, note_id::16-big>> ->
        handle_get_note_first(note_id, context)

      # Get rest of post body
      <<0, 0, 0x68, 0x40, note_id::16-big>> ->
        handle_get_note_rest(note_id, context)

      # Get replies for current post
      <<0, 0, 0x68, 0x28, 0::16-big, mmdd::binary-size(4), hhmm::binary-size(4)>> ->
        handle_start_reply_traversal(mmdd, hhmm, context)

      # Get rest of reply body
      <<0, 0, 0x68, 0x61>> ->
        handle_get_reply_rest(context)

      # Get next reply
      <<0, 0, 0x68, 0x21>> ->
        handle_get_next_reply(context)

      # Submit public note
      <<0, 0, 0xFF, rest::binary>> ->
        handle_submit_post(context, rest)

      # submit public reply
      <<0, 0, 0xFE, in_reply_to::16-big, rest::binary >> ->
        handle_submit_post(context, rest, in_reply_to)

      <<0, 0, 0xFD, from_id::binary-size(7), to_id::binary-size(7), mmdd::binary-size(4) >> ->
        handle_criteria_search(context, from_id, to_id, mmdd)

      _ ->
        handle_unknown_request(payload, context)
    end

    case response do
      {:ok, payload} -> {:ok, context, DiaPacket.encode(Fm0.make_response(payload, request))}
      _ -> {:ok, context}
    end
  end

  defp handle_submit_post(context, payload, in_reply_to \\ nil) do
    <<
      topic_id::16-big,
      to_id::binary-size(7),
      subject_len,
      subject::binary-size(subject_len),
      body_len::16-big,
      body::binary-size(body_len),
    >> = payload

    # Determine the to_name - if it's 7 spaces, use "ALL"
    to_id = if String.trim(to_id) == "", do: "ALL", else: to_id

    # Build the post attributes
    post_attrs = %{
      from_id: context.user.id,
      to_id: to_id,
      subject: subject,
      body: body,
      topic_id: topic_id,
      sent_date: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    # Add in_reply_to if this is a reply (non-zero value)
    post_attrs = if in_reply_to != nil do
      # The in_reply_to appears to be an index, so we need to get the actual post ID
      actual_reply_to_id = Enum.at(context.bb.note_ids, in_reply_to - 1)
      Map.put(post_attrs, :in_reply_to, actual_reply_to_id)
    else
      post_attrs
    end

    # Create the post
    case Repo.insert(%Post{} |> Ecto.Changeset.change(post_attrs)) do
      {:ok, _post} ->
        Logger.debug("Successfully created post from user #{context.user.id}")
        {context, {:ok, <<0>>}}  # Return success code

      {:error, changeset} ->
        Logger.error("Failed to create post: #{inspect(changeset.errors)}")
        {context, {:ok, <<0xFF>>}}  # Return error code
    end
  end

  defp handle_enter_club(club_handle, context) do
    club = Repo.get_by(Club, handle: club_handle)

    case club do
      nil ->
        Logger.warning("Club with handle #{club_handle} not found")
        response = <<0, 0xFF::16, 0::32, 0::16-big>>
        {context, {:ok, response}}

      %Club{id: club_id, name: name} ->
        if is_nil(context.user) do
          Logger.error("No user in context for bulletin board access")
          response = <<0, 0xFF::16, 0::32, 0::16-big>>
          {context, {:ok, response}}
        else
          # Get or create the user's last read date for this club
          # This will create the UserClub record if it doesn't exist
          last_read_mmdd = case Repo.get_by(UserClub, user_id: context.user.id, club_id: club_id) do
            nil ->
              # First time entering this club - create the UserClub record
              # IMPORTANT: Truncate DateTime to remove microseconds
              {:ok, _} = Repo.insert(%UserClub{
                user_id: context.user.id,
                club_id: club_id,
                last_read_date: DateTime.utc_now() |> DateTime.truncate(:second)
              })
              Calendar.strftime(Date.utc_today(), "%m%d")

            %UserClub{last_read_date: last_read} ->
              Calendar.strftime(last_read, "%m%d")
          end

          # Store club_id in context for later use
          updated_context = Map.put(context, :current_club_id, club_id)

          response = <<
            0,      # TODO return 0x5 if board editor privileges
            6::16,  # max pages per post
            last_read_mmdd::binary-size(4),
            byte_size(name)::16-big,
            name::binary
          >>

          {updated_context, {:ok, response}}
        end
    end
  end

  defp handle_list_topics(club_handle, context) do
    club = Club
           |> where([c], c.handle == ^club_handle)
           |> preload(topics: ^from(t in Topic, order_by: [asc: t.id]))
           |> Repo.one()

    topics = if club, do: club.topics, else: []

    if is_nil(club), do: Logger.warning("Club with handle #{club_handle} not found")

    topics_binary = build_topics_binary(topics)

    response = <<
      0x1,                          # Response type
      0::16-big,                    # Unknown value
      length(topics)::16-big,       # Number of topics
      0::16-big,                    # Unknown value
      topics_binary::binary         # All topic data
    >>

    {context, {:ok, response}}
  end

  defp handle_criteria_search(context, from_id, to_id, mmdd) do
    # Parse the date threshold
    month = String.to_integer(binary_part(mmdd, 0, 2))
    day = String.to_integer(binary_part(mmdd, 2, 2))

    # Use beginning of the day as the time threshold
    current_year = Date.utc_today().year
    {:ok, naive_date} = NaiveDateTime.new(current_year, month, day, 0, 0, 0)
    threshold_datetime = DateTime.from_naive!(naive_date, "Etc/UTC")

    # Get the club_id from context (should have been set by handle_enter_club)
    # Check if context has the bb map and current_club_id
    club_id = case context do
      %{bb: %{current_club_id: id}} when not is_nil(id) -> id
      %{current_club_id: id} when not is_nil(id) -> id
      _ -> nil
    end

    if is_nil(club_id) do
      Logger.error("No club_id in context for criteria search")
      {context, {:ok, <<0xFF>>}}  # Error, send an FM9 or FM64?
    else
      # Build the search criteria
      from_criteria = if String.trim(from_id) == "", do: nil, else: String.trim(from_id)
      to_criteria = if String.trim(to_id) == "", do: nil, else: String.trim(to_id)

      # Search for posts matching criteria across all topics in the club
      note_ids = search_posts_by_criteria(club_id, from_criteria, to_criteria, threshold_datetime)

      # Update the user's last read date for this club
      update_last_read_date(context.user.id, club_id)

      # Store results in context, similar to handle_start_note_cursor
      context = Map.merge(context, %{
        bb: %{
          note_ids: note_ids,
          offset: 0,
          topic_id: nil,  # No specific topic for criteria search
          current_post_id: nil,
          reply_ids: [],
          reply_offset: 0,
          rest: nil,
          current_club_id: club_id  # Preserve the club_id
        }
      })

      # Return the index page with search results
      {context, {:ok, get_index_page(context.bb)}}
    end
  end

  # New helper function to search posts by criteria across all topics in a club
  defp search_posts_by_criteria(club_id, from_criteria, to_criteria, threshold_datetime) do
    query = from p in Post,
                 join: t in Topic, on: p.topic_id == t.id,
                 left_join: r in Post, on: r.in_reply_to == p.id,
                 where: t.club_id == ^club_id and is_nil(p.in_reply_to),
                 where: p.sent_date >= ^threshold_datetime or r.sent_date >= ^threshold_datetime,
                 group_by: p.id,
                 order_by: [asc: p.sent_date],
                 select: p.id

    # Apply from_id filter if specified
    query = if from_criteria do
      where(query, [p, _t, _r], p.from_id == ^from_criteria)
    else
      query
    end

    # Apply to_id filter if specified
    # Note: "ALL" should match empty to_name or nil
    query = if to_criteria do
      if to_criteria == "ALL" do
        where(query, [p, _t, _r], p.to_id == "" or is_nil(p.to_id) or p.to_id == "ALL")
      else
        where(query, [p, _t, _r], p.to_id == ^to_criteria)
      end
    else
      query
    end

    Repo.all(query)
  end

  defp handle_start_note_cursor(mon, day, min, hour, topic_id, context) do
    Logger.debug("Starting note cursor for topic #{topic_id} from #{mon}/#{day} #{hour}:#{min}")

    threshold_datetime = parse_datetime(mon, day, min, hour)
    note_ids = get_posts_since_threshold(topic_id, threshold_datetime)

    topic = Repo.get(Topic, topic_id)
    update_last_read_date(context.user.id, topic.club_id)

    context = Map.merge(context, %{
      bb: %{
        note_ids: note_ids,
        offset: 0,
        topic_id: topic_id,
        current_post_id: nil,
        reply_ids: [],
        reply_offset: 0,
        rest: nil
      }
    })

    {context, {:ok, get_index_page(context.bb)}}
  end

  defp handle_select_note_cursor_page(page_no, context) do
    Logger.debug("note pagination, select page: #{page_no}")

    new_offset = (page_no - 1) * 3
    new_context = %{context | bb: %{context.bb | offset: new_offset}}

    {new_context, {:ok, get_index_page(new_context.bb)}}
  end

  defp handle_navigate_note_cursor(direction, context) do
    Logger.debug("note pagination, direction: #{direction}")

    new_offset = calculate_new_offset(direction, context.bb.offset, length(context.bb.note_ids))
    new_context = %{context | bb: %{context.bb | offset: new_offset}}

    {new_context, {:ok, get_index_page(new_context.bb)}}
  end

  defp handle_get_note_first(note_id, context) do
    Logger.debug("Getting note #{note_id} header and first page")

    actual_post_id = Enum.at(context.bb.note_ids, note_id - 1)
    {response, rest} = get_post_by_id(actual_post_id)

    new_context = %{context | bb: %{context.bb |
      rest: rest,
      current_post_id: actual_post_id
    }}

    {new_context, {:ok, response}}
  end

  defp handle_get_note_rest(_note_id, context) do
    Logger.debug("Getting rest of note body")

    response = <<
      0x0,
      0x0,
      byte_size(context.bb.rest)::16-big,
      context.bb.rest::binary
    >>

    new_context = %{context | bb: %{context.bb | rest: nil}}
    {new_context, {:ok, response}}
  end

  defp handle_start_reply_traversal(mmdd, hhmm, context) do
    # Check if we have a current post
    if is_nil(context.bb) or is_nil(context.bb.current_post_id) do
      {context, {:ok, <<0x0, 0x0, 0::16-big>>}}
    else
      threshold_datetime = parse_datetime_from_mmdd_hhmm(mmdd, hhmm)
      replies_with_dates = get_all_replies_with_dates(context.bb.current_post_id)
      reply_ids = Enum.map(replies_with_dates, & &1.id)
      starting_offset = find_reply_starting_offset(replies_with_dates, threshold_datetime)
      available_replies = length(reply_ids) - starting_offset

      if available_replies > 0 do
        first_reply_id = Enum.at(reply_ids, starting_offset)
        {response, rest} = get_post_by_id(first_reply_id, starting_offset + 1)

        new_context = %{context | bb: %{context.bb |
          reply_ids: reply_ids,
          reply_offset: starting_offset,
          rest: rest
        }}

        {new_context, {:ok, response}}
      else
        {context, {:ok, <<0x0, 0x0, 0::16-big>>}}
      end
    end
  end

  defp handle_get_reply_rest(context) do
    Logger.debug("Getting rest of reply body")

    response = <<
      0x0,
      0x0,
      byte_size(context.bb.rest || <<>>)::16-big,
      (context.bb.rest || <<>>)::binary
    >>

    new_context = %{context | bb: %{context.bb | rest: nil}}
    {new_context, {:ok, response}}
  end

  defp handle_get_next_reply(context) do
    Logger.debug("Getting next reply")

    new_offset = context.bb.reply_offset + 1

    if new_offset < length(context.bb.reply_ids) do
      next_reply_id = Enum.at(context.bb.reply_ids, new_offset)
      {response, rest} = get_post_by_id(next_reply_id, new_offset + 1)

      new_context = %{context | bb: %{context.bb |
        reply_offset: new_offset,
        rest: rest
      }}

      {new_context, {:ok, response}}
    else
      {context, {:ok, <<0x0, 0x0, 0::16-big>>}}
    end
  end

  defp handle_unknown_request(request, context) do
    Logger.warning("unhandled bulletin board request: #{inspect(request, base: :hex, limit: :infinity)}")
    {context, {:ok, <<0>>}}
  end

  # Helper Functions

  defp parse_datetime(mon, day, min, hour) do
    current_year = Date.utc_today().year
    month = String.to_integer(mon)
    day_int = String.to_integer(day)
    minute = String.to_integer(min)
    hour_int = String.to_integer(hour)

    {:ok, naive_datetime} = NaiveDateTime.new(current_year, month, day_int, hour_int, minute, 0)
    DateTime.from_naive!(naive_datetime, "Etc/UTC")
  end

  defp parse_datetime_from_mmdd_hhmm(mmdd, hhmm) do
    month = String.to_integer(binary_part(mmdd, 0, 2))
    day = String.to_integer(binary_part(mmdd, 2, 2))
    hour = String.to_integer(binary_part(hhmm, 0, 2))
    minute = String.to_integer(binary_part(hhmm, 2, 2))

    current_year = Date.utc_today().year
    {:ok, threshold_datetime} = NaiveDateTime.new(current_year, month, day, hour, minute, 0)

    threshold_datetime
  end

  defp build_topics_binary(topics) do
    topics
    |> Enum.map(fn topic ->
      <<
        byte_size(topic.title)::16-big,
        topic.title::binary,
        1,                              # Unknown byte (placeholder)
        2::32-big,                      # Unknown 32-bit value (placeholder)
        topic.id::16-big
      >>
    end)
    |> IO.iodata_to_binary()
  end

  defp calculate_new_offset(direction, current_offset, _total_posts) do
    case direction do
      0x01 -> current_offset + 3                            # 0x01 = Next page (forward)
      0x02 -> max(0, current_offset - 3)                    # 0x02 = Prev page (backward)
      0x10 -> 0                                             # 0x10 = Reset to beginning
      _ -> current_offset
    end
  end

  defp find_reply_starting_offset(replies_with_dates, threshold_datetime) do

    result = replies_with_dates
             |> Enum.find_index(fn %{sent_date: date} ->
      comparison = NaiveDateTime.compare(date, threshold_datetime)
      _is_after_or_equal = comparison in [:gt, :eq]
    end)

    _offset = result || 0
  end

  # Database Queries

  defp get_posts_since_threshold(topic_id, threshold_datetime) do
    Repo.all(
      from p in Post,
      left_join: r in Post, on: r.in_reply_to == p.id,
      where: p.topic_id == ^topic_id and is_nil(p.in_reply_to),
      where: p.sent_date >= ^threshold_datetime or r.sent_date >= ^threshold_datetime,
      group_by: p.id,
      order_by: [asc: p.sent_date],
      select: p.id
    )
  end

  defp get_all_replies_with_dates(post_id) do
    Repo.all(
      from p in Post,
      where: p.in_reply_to == ^post_id,
      order_by: [asc: p.sent_date],
      select: %{id: p.id, sent_date: p.sent_date}
    )
  end

  defp get_all_replies_with_max_date(post_id) do
    replies = Repo.all(
      from p in Post,
      where: p.in_reply_to == ^post_id,
      order_by: [asc: p.sent_date],
      select: %{id: p.id, sent_date: p.sent_date}
    )

    case replies do
      [] -> {[], nil}
      _ ->
        ids = Enum.map(replies, & &1.id)
        max_date = replies |> Enum.map(& &1.sent_date) |> Enum.max()
        {ids, max_date}
    end
  end


  def get_post_by_id(id, result_number \\ nil) do
    {_reply_ids, newest_reply_date} = get_all_replies_with_max_date(id)

    post = Repo.one(
      from p in Post,
      where: p.id == ^id,
      left_join: r in Post, on: r.in_reply_to == p.id,
      left_join: from_user in User, on: from_user.id == p.from_id,
      left_join: to_user in User, on: to_user.id == p.to_id and p.to_id != "" and not is_nil(p.to_id),
      preload: [:topic],
      group_by: [p.id, from_user.first_name, from_user.last_name, to_user.first_name, to_user.last_name],
      select: %Post{p |
        reply_count: count(r.id),
        last_reply_date: max(r.sent_date),
        from_name: fragment("COALESCE(? || ' ' || ?, ?, ?)",
          from_user.first_name, from_user.last_name, from_user.first_name, p.from_id),
        to_name: fragment("COALESCE(? || ' ' || ?, ?, ?)",
          to_user.first_name, to_user.last_name, to_user.first_name, p.to_id)
      }
    )

    sent_mmdd = Calendar.strftime(post.sent_date, "%m%d")
    sent_hhmm_24hr = Calendar.strftime(post.sent_date, "%H%M")
    _last_mmdd = if post.last_reply_date do
      Calendar.strftime(post.last_reply_date, "%m%d")
    else
      "    "
    end

    newest_mmddHHMM = if newest_reply_date do
      Calendar.strftime(newest_reply_date, "%m%d%H%M")
    else
      "        "
    end

    to_name = if is_nil(post.to_id) or post.to_id == "", do: "ALL", else: post.to_name

    {first, rest} = case post.body do
      <<first::binary-size(280), rest::binary>> -> {first, rest}
      body -> {body, <<>>}
    end

    response = <<
      0x0,
      0x0,
      post.from_id::binary,
      sent_mmdd::binary,
      sent_hhmm_24hr::binary-size(4),
      newest_mmddHHMM::binary-size(8),
      (result_number || 0)::16-big,
      (post.reply_count || 0)::16-big,
      0,
      post.topic_id::16-big,
      byte_size(post.topic.title)::16-big,
      post.topic.title::binary,
      byte_size(to_name)::16-big,
      to_name::binary,
      byte_size(post.from_name)::16-big,
      post.from_name::binary,
      byte_size(post.subject)::16-big,
      post.subject::binary,
      byte_size(post.body)::16-big,
      byte_size(first)::16-big,
      first::binary
    >>

    {response, rest}
  end

  defp get_index_page(%{note_ids: note_ids, offset: offset}, page_size \\ 3) do
    page_note_ids = Enum.slice(note_ids, offset, page_size)
    total_notes = length(note_ids)
    notes_this_page = length(page_note_ids)

    notes_data = if notes_this_page > 0 do
      notes_with_stats = Repo.all(
        from p in Post,
        where: p.id in ^page_note_ids,
        left_join: r in Post, on: r.in_reply_to == p.id,
        left_join: from_user in User, on: from_user.id == p.from_id,
        left_join: to_user in User, on: to_user.id == p.to_id and p.to_id != "" and not is_nil(p.to_id),
        group_by: [p.id, p.sent_date, p.to_id, p.from_id, p.subject, from_user.first_name, from_user.last_name, to_user.first_name, to_user.last_name],
        order_by: [asc: p.sent_date],
        select: %{
          sent_date: p.sent_date,
          to_id: p.to_id,
          subject: p.subject,
          reply_count: count(r.id),
          last_reply_date: max(r.sent_date),
          from_name: fragment("COALESCE(? || ' ' || ?, ?, ?)",
            from_user.first_name, from_user.last_name, from_user.first_name, p.from_id),
          to_name: fragment("COALESCE(? || ' ' || ?, ?, ?)",
            to_user.first_name, to_user.last_name, to_user.first_name, p.to_id)
        }
      )

      notes_with_stats
      |> Enum.map(fn post ->
        sent_mmdd = Calendar.strftime(post.sent_date, "%m%d")
        last_reply_mmdd = if post.last_reply_date do
          Calendar.strftime(post.last_reply_date, "%m%d")
        else
          "    "
        end

        to_name = if is_nil(post.to_id) or post.to_id == "", do: "ALL", else: post.to_name

        <<
          sent_mmdd::binary-size(4),
          last_reply_mmdd::binary-size(4),
          (post.reply_count || 0)::16-big,
          byte_size(to_name)::16-big, to_name::binary,
          byte_size(post.from_name)::16-big, post.from_name::binary,
          byte_size(post.subject)::16-big, post.subject::binary
        >>
      end)
      |> IO.iodata_to_binary()
    else
      <<>>
    end

    <<
      0x1,
      0x0,
      0x0::32-big,
      total_notes::16-big,
      notes_this_page::16-big,
      notes_data::binary
    >>
  end

  defp update_last_read_date(user_id, club_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(UserClub, user_id: user_id, club_id: club_id) do
      nil ->
        # First time reading this club, create the record
        %UserClub{}
        |> UserClub.changeset(%{
          user_id: user_id,
          club_id: club_id,
          last_read_date: now
        })
        |> Repo.insert()

      existing ->
        # Update existing record
        existing
        |> UserClub.changeset(%{last_read_date: now})
        |> Repo.update()
    end
    |> case do
         {:ok, _} ->
           Logger.debug("Updated last read date for user #{user_id} in club #{club_id}")
         {:error, changeset} ->
           Logger.error("Failed to update last read date: #{inspect(changeset.errors)}")
       end
  end
end
