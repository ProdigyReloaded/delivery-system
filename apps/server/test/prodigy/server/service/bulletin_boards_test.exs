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

defmodule Prodigy.Server.Service.BulletinBoards.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Server

  import Ecto.Changeset

  alias Prodigy.Core.Data.{Club, Household, Post, Topic, User, UserClub, Repo}
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router

  require Logger

  @moduletag :capture_log

  @today DateTime.to_date(DateTime.utc_now())

  setup do
    # Create test household and user
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F", date_enrolled: @today,
        first_name: "Jane", last_name: "Doe"}
      |> User.changeset(%{password: "foobaz"}),
      %User{id: "AAAA12B", gender: "M", date_enrolled: @today,
        first_name: "John", last_name: "Smith"}
      |> User.changeset(%{password: "barbaz"})
    ])
    |> Repo.insert!()

    # Create test club structure
    club = Repo.insert!(%Club{
      handle: "TST",
      name: "Test Club"
    })

    topic1 = Repo.insert!(%Topic{
      club_id: club.id,
      title: "General Discussion",
      closed: false
    })

    topic2 = Repo.insert!(%Topic{
      club_id: club.id,
      title: "Technical Support",
      closed: false
    })

    {:ok, router_pid} = GenServer.start_link(Router, nil)

    # Allow the router to see the test data
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), router_pid)

    [
      router_pid: router_pid,
      club: club,
      topic1: topic1,
      topic2: topic2
    ]
  end

  # Helper functions
  defp enter_club(context, club_handle) do
    {:ok, response} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0x65, club_handle::binary-size(3)>>
    })
    response
  end

  defp list_topics(context, club_handle) do
    {:ok, response} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0x0F, club_handle::binary-size(3), 0x0C>>
    })
    response
  end

  defp start_note_cursor(context, month, day, min, hour, topic_id) do
    {:ok, response} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0x67, 0x24,
        month::binary-size(2), day::binary-size(2),
        min::binary-size(2), hour::binary-size(2),
        topic_id::16-big>>
    })
    response
  end

  defp submit_public_note(context, topic_id, to_name, subject, body) do
    subject_bin = subject
    body_bin = body

    {:ok, response} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0xFF,
        topic_id::16-big,
        to_name::binary-size(7),
        byte_size(subject_bin),
        subject_bin::binary,
        byte_size(body_bin)::16-big,
        body_bin::binary>>
    })
    response
  end

  defp submit_reply(context, topic_id, in_reply_to, to_name, subject, body) do
    subject_bin = subject
    body_bin = body

    {:ok, response} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0xFE,
        in_reply_to::16-big,
        topic_id::16-big,
        to_name::binary-size(7),
        byte_size(subject_bin),
        subject_bin::binary,
        byte_size(body_bin)::16-big,
        body_bin::binary>>
    })
    response
  end

  # Tests
  test "enter club creates user-club association", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    # Initially no UserClub record
    assert nil == Repo.get_by(UserClub, user_id: "AAAA12A", club_id: context.club.id)

    # Enter the club - this should create the UserClub record
    <<_::binary-size(16), status, _rest::binary>> = enter_club(context, "TST")
    assert status == 0  # Success status

    # Force a small delay to ensure DB write completes
    Process.sleep(100)

    # Should now have a UserClub record
    user_club = Repo.get_by(UserClub, user_id: "AAAA12A", club_id: context.club.id)
    assert user_club != nil
    assert user_club.user_id == "AAAA12A"
    assert user_club.club_id == context.club.id

    logoff(context.router_pid)
  end

  test "list topics for club", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    # Verify that topics exist in the database first
    topics = Topic |> Ecto.Query.where([t], t.club_id == ^context.club.id) |> Repo.all()
    assert length(topics) == 2, "Expected 2 topics in database, got #{length(topics)}"

    # Verify club exists
    club = Repo.get_by!(Club, handle: "TST")
    assert club.id == context.club.id

    # Need to enter club first to set context
    response = enter_club(context, "TST")

    # Check that enter_club succeeded
    <<_::binary-size(16), status, _rest::binary>> = response
    assert status == 0, "Failed to enter club, status: #{status}"

    response = list_topics(context, "TST")

    # Parse the response - the structure appears to be:
    # 16 bytes DIA header, then 0x01, then 2 bytes, then count as 16-bit big-endian
    <<_dia_header::binary-size(16),
      0x01,
      _unknown::16-big,
      count::16-big,
      _unknown2::16-big,
      rest::binary>> = response

    assert count == 2, "Expected 2 topics, got #{count}"

    if count > 0 do
      # Parse first topic
      <<title1_len::16-big, title1::binary-size(title1_len),
        _::8, _::32, id1::16-big, rest2::binary>> = rest
      assert title1 == "General Discussion"
      assert id1 == context.topic1.id

      # Parse second topic
      <<title2_len::16-big, title2::binary-size(title2_len),
        _::8, _::32, id2::16-big, _rest3::binary>> = rest2
      assert title2 == "Technical Support"
      assert id2 == context.topic2.id
    end

    logoff(context.router_pid)
  end

  test "submit and retrieve public note", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    # Enter club first
    enter_club(context, "TST")

    # Submit a public note
    submit_public_note(context, context.topic1.id, "       ",
      "Test Subject", "This is a test message body.")

    # Verify post was created
    posts = Repo.all(Post)
    assert length(posts) == 1
    post = hd(posts)
    assert post.from_id == "AAAA12A"
    assert post.to_id == "ALL"
    assert post.subject == "Test Subject"
    assert post.body == "This is a test message body."
    assert post.topic_id == context.topic1.id

    logoff(context.router_pid)
  end

  test "submit and retrieve reply", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    enter_club(context, "TST")

    # Create initial post
    submit_public_note(context, context.topic1.id, "       ",
      "Original Post", "This is the original post.")

    # Start note cursor to get the post
    response = start_note_cursor(context, "01", "01", "00", "00", context.topic1.id)
    <<_dia_header::binary-size(16),
      0x01,
      _unknown::8,
      _unknown2::32-big,
      total::16-big,
      _rest::binary>> = response
    assert total == 1

    # Submit a reply (using index 1 for the first post)
    submit_reply(context, context.topic1.id, 1, "       ",
      "Re: Original Post", "This is a reply.")

    # Verify reply was created
    posts = Post |> Ecto.Query.order_by([p], asc: p.sent_date) |> Repo.all()
    assert length(posts) == 2

    original = Enum.at(posts, 0)
    reply = Enum.at(posts, 1)

    assert reply.in_reply_to == original.id
    assert reply.subject == "Re: Original Post"
    assert reply.body == "This is a reply."

    logoff(context.router_pid)
  end

  test "note pagination", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    enter_club(context, "TST")

    # Create 5 posts to test pagination
    for i <- 1..5 do
      response = submit_public_note(context, context.topic1.id, "       ",
        "Post #{i}", "Body of post #{i}")
      # Verify each post submission succeeded
      <<_::binary-size(16), status, _rest::binary>> = response
      assert status == 0, "Failed to create post #{i}"
    end

    # Verify posts were created with correct attributes
    posts = Post
            |> Ecto.Query.where([p], p.topic_id == ^context.topic1.id)
            |> Ecto.Query.order_by([p], asc: p.sent_date)
            |> Repo.all()

    assert length(posts) == 5, "Expected 5 posts in database, got #{length(posts)}"

    # Check that posts are top-level (not replies)
    for post <- posts do
      assert is_nil(post.in_reply_to), "Post #{post.subject} should have nil in_reply_to, got: #{inspect(post.in_reply_to)}"
    end

    # Get first page - use a date in the past to ensure we get all posts
    response = start_note_cursor(context, "01", "01", "00", "00", context.topic1.id)

    # Parse the index page response - notes_this_page is 16-bit, not 8-bit!
    <<_dia_header::binary-size(16),
      0x01,                  # Response type
      0x00,                  # Unknown byte
      _unknown::32-big,      # Unknown 32-bit value
      total::16-big,         # Total notes (16-bit)
      on_page::16-big,       # Notes on this page (16-bit, not 8-bit!)
      _rest::binary>> = response

    assert total == 5, "Expected 5 total posts, got #{total}"
    assert on_page == 3, "Expected 3 posts on first page, got #{on_page}"

    # Navigate to next page (direction 0x01 = next page in actual protocol)
    {:ok, response2} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0x67, 0x01, "01", "01",  # 0x01 for next!
        2::16-big, "xx">>
    })

    <<_dia_header2::binary-size(16),
      0x01,
      0x00,
      _unknown2::32-big,
      ^total::16-big,        # Total should be same
      on_page2::16-big,      # Notes on this page (16-bit!)
      _rest2::binary>> = response2

    assert on_page2 == 2, "Expected 2 posts on second page, got #{on_page2}"

    logoff(context.router_pid)
  end

  test "note pagination - direct page selection", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    enter_club(context, "TST")

    # Create 8 posts to have 3 pages (3, 3, 2)
    for i <- 1..8 do
      response = submit_public_note(context, context.topic1.id, "       ",
        "Post #{i}", "Body of post #{i}")
      <<_::binary-size(16), status, _rest::binary>> = response
      assert status == 0, "Failed to create post #{i}"
    end

    # Initialize the note cursor to establish context
    response = start_note_cursor(context, "01", "01", "00", "00", context.topic1.id)
    <<_dia_header::binary-size(16),
      0x01, 0x00, _unknown::32-big,
      total::16-big,
      on_page::16-big,
      rest::binary>> = response

    assert total == 8
    assert on_page == 3  # First page has 3 posts

    # Parse first post subject to verify we're on page 1
    <<_date1::binary-size(4), _date2::binary-size(4), _count::16-big,
      to_len::16-big, _to::binary-size(to_len),
      from_len::16-big, _from::binary-size(from_len),
      subj_len::16-big, subject::binary-size(subj_len),
      _rest::binary>> = rest
    assert subject == "Post 1"

    # Jump directly to page 2 using the new page selection feature
    {:ok, response2} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0x67, 0x08,  # 0x08 for page selection
        2::16-big,                      # Page 2
        "01", "01",                     # Month/day (ignored)
        "dummy">>                       # Rest (ignored)
    })

    <<_dia_header2::binary-size(16),
      0x01, 0x00, _unknown2::32-big,
      ^total::16-big,
      on_page2::16-big,
      rest2::binary>> = response2

    assert on_page2 == 3  # Page 2 also has 3 posts (posts 4-6)

    # Parse first post subject to verify we're on page 2
    <<_date1b::binary-size(4), _date2b::binary-size(4), _countb::16-big,
      to_len2::16-big, _to2::binary-size(to_len2),
      from_len2::16-big, _from2::binary-size(from_len2),
      subj_len2::16-big, subject2::binary-size(subj_len2),
      _rest2b::binary>> = rest2
    assert subject2 == "Post 4"  # First post on page 2

    # Jump directly to page 3
    {:ok, response3} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0x67, 0x08,
        3::16-big,                      # Page 3
        "01", "01",
        "dummy">>
    })

    <<_dia_header3::binary-size(16),
      0x01, 0x00, _unknown3::32-big,
      ^total::16-big,
      on_page3::16-big,
      rest3::binary>> = response3

    assert on_page3 == 2  # Page 3 has only 2 posts (posts 7-8)

    # Parse first post subject to verify we're on page 3
    <<_date1c::binary-size(4), _date2c::binary-size(4), _countc::16-big,
      to_len3::16-big, _to3::binary-size(to_len3),
      from_len3::16-big, _from3::binary-size(from_len3),
      subj_len3::16-big, subject3::binary-size(subj_len3),
      _rest3b::binary>> = rest3
    assert subject3 == "Post 7"  # First post on page 3

    logoff(context.router_pid)
  end


  test "criteria search", context do
    # First user creates a post
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")
    enter_club(context, "TST")

    # Create post from User A
    submit_public_note(context, context.topic1.id, "       ",
      "From User A", "Message from A")

    # Use normal logoff (not disconnect) to keep router alive
    logoff_relogon(context.router_pid)

    # Second user creates a post
    logon(context.router_pid, "AAAA12B", "barbaz", "06.03.17")
    enter_club(context, "TST")

    # Create post from User B to User A
    submit_public_note(context, context.topic1.id, "AAAA12A",
      "To User A", "Private message to A")

    # Now search for posts from AAAA12A
    {:ok, response} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0xFD,
        "AAAA12A",  # from_id
        "       ",  # to_name (ALL)
        "0101">>    # mmdd
    })

    <<_dia_header::binary-size(16),
      0x01,
      0x00,
      _unknown::32-big,
      found::16-big,
      _rest::binary>> = response

    assert found == 1, "Expected to find 1 post from User A, found #{found}"

    logoff(context.router_pid)
  end

  test "reply tree traversal", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    enter_club(context, "TST")

    # Create a post with multiple nested replies
    submit_public_note(context, context.topic1.id, "       ",
      "Original", "Original post")

    # Get the post to establish context
    start_note_cursor(context, "01", "01", "00", "00", context.topic1.id)

    # Add replies
    submit_reply(context, context.topic1.id, 1, "       ",
      "Reply 1", "First reply")
    submit_reply(context, context.topic1.id, 1, "       ",
      "Reply 2", "Second reply")

    # Start reply traversal
    {:ok, response} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0x68, 0x28, 0x00, 0x00,
        "0101", "0000">>  # mmdd, hhmm
    })

    # Check we got a response (not empty)
    assert byte_size(response) > 16, "Expected reply content"

    # Get next reply
    {:ok, response2} = Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x03, 0x00, 0x00, 0x68, 0x21>>
    })

    # Check we got another response
    assert byte_size(response2) > 16, "Expected second reply content"

    logoff(context.router_pid)
  end

  test "complete user journey - read and reply to discussion", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    # User enters Test Club
    enter_club(context, "TST")

    # User lists topics
    list_topics(context, "TST")

    # User enters General Discussion topic and views recent posts
    start_note_cursor(context, "01", "01", "00", "00", context.topic1.id)

    # User posts a new message
    submit_public_note(context, context.topic1.id, "       ",
      "Welcome!", "Hello everyone, glad to be here.")

    # Verify the complete flow worked
    posts = Repo.all(Post)
    assert length(posts) == 1
    assert hd(posts).subject == "Welcome!"

    user_club = Repo.get_by(UserClub, user_id: "AAAA12A", club_id: context.club.id)
    assert user_club != nil

    logoff(context.router_pid)
  end

  test "database visibility in router", context do
    # Create a unique club to test visibility
    test_club = Repo.insert!(%Club{
      handle: "DBT",
      name: "DB Test Club"
    })

    # Verify it's in the database from the test process
    found_club = Repo.get(Club, test_club.id)
    assert found_club != nil
    assert found_club.handle == "DBT"

    # Now try to access it through the router
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    # Try to enter the test club
    response = enter_club(context, "DBT")

    # If we get an error response, the router can't see the data
    <<_::binary-size(16), status, _rest::binary>> = response
    assert status == 0, "Router couldn't find club created in test (status: #{status})"

    logoff(context.router_pid)
  end
end
