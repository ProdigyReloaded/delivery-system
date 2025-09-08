# Copyright 2022, Phillip Heller
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

defmodule Prodigy.Server.Service.Messaging.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Server

  import Ecto.Changeset

  alias Prodigy.Core.Data.{Household, Message, User}
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router
  alias Prodigy.Server.Service.Messaging

  require Logger

  @moduletag :capture_log

  @today DateTime.to_date(DateTime.utc_now())

  setup do
    %Household{id: "AAAA12", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", gender: "F", date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()

    {:ok, router_pid} = GenServer.start_link(Router, nil)

    # would like to put logon here, and logoff in a callback, but there is only on_exit which is called after
    # the Router is terminated by ExUnit, which would mean the logoff would get called after the Repo supervisor is
    # shutdown

    [router_pid: router_pid]
  end

  defp get_mailbox_page(context, page) do
    # general pattern here is:
    # :ok - the Router returns this first as an indication to DIA to respond to the RS
    #     vvvv--- this is the binary response
    #        vvvvvvvvvvvvvvvvvv--- there is a 16 byte DIA FM0 header we ignore
    #                            vvvvvvvvvvvvv--- total messages in the user's mailbox
    #                                           vvvvvvvvv--- messages on the requested mailbox page
    #                                                      vvvvvvvvvvvv--- headers for the messages on this page
    {:ok, <<_::binary-size(16), total::16-big, this_page, rest::binary>>} =
      Router.handle_packet(context.router_pid, %Fm0{
        src: 0x0,
        dest: 0x00D200,
        logon_seq: 0,
        message_id: 0,
        function: Fm0.Function.APPL_0,
        payload: <<0x01, 0x0A, page, "this is ignored"::binary>>
      })

    {total, this_page, rest}
  end

  defp get_message(context, index) do
    {:ok, <<_::binary-size(16), 0::104, length::16-big, content::binary-size(length)>>} =
      Router.handle_packet(context.router_pid, %Fm0{
        src: 0x0,
        dest: 0x00D200,
        logon_seq: 0,
        message_id: 0,
        function: Fm0.Function.APPL_0,
        payload: <<0x01, 0x03, 0x03, index::16-big, 0x01, 0xF4>>
      })

    content
  end

  test "send message", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    messages =
      Message
      |> Repo.all()

    assert(Enum.empty?(messages))

    message_payload = <<
      0x01,
      # indicates "Send a message" to the messaging service
      0x02,
      # send to 2 user ids
      2::16-big,
      "BBBB12B",
      "CCCC12C",
      # length of all the "others" to follow
      21::16-big,
      # length of "JOHN DOE"
      8,
      "JOHN DOE",
      # length of "SALLY SMITH"
      11,
      "SALLY SMITH",
      11,
      "Testing 123",
      52::16-big,
      "The quick brown fox jumped over the lazy dog's back."
    >>

    Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x01>> <> message_payload
    })

    messages =
      Message
      |> Repo.all()

    # there should now be two messages, one to BBBB12B and one to CCCC12C
    assert(length(messages) == 2)

    logoff(context.router_pid)
  end

  test "retrieve mailbox", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    # RS starts on page 1; page 0 case is not handled
    # get_mailbox_page returns {total, this_page, rest::binary}

    # User starts with no mail
    {0, 0, _rest} = get_mailbox_page(context, 1)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 1", "Test 1")

    # Client must reload page 1 to see new messages (simulating leaving and re-entering mailbox)
    {1, 1, _rest} = get_mailbox_page(context, 1)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 2", "Test 2")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 3", "Test 3")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 4", "Test 4")

    # Client reloads mailbox
    {4, 4, _rest} = get_mailbox_page(context, 1)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 5", "Test 5")

    # Client reloads mailbox again
    {5, 4, _rest} = get_mailbox_page(context, 1)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 6", "Test 6")

    # Client reloads mailbox and then navigates to page 2
    {6, 4, _rest} = get_mailbox_page(context, 1)
    {6, 2, rest} = get_mailbox_page(context, 2)

    # make sure the messages on page 2 are as expected
    # Messages should be Test 2 and Test 1 (oldest) since we show newest first
    # and page 1 has Test 6, 5, 4, 3

    # The client indices for page 2 should be 4 and 5
    <<4::16-big, "ZZZZ00A", 0, 0, sent_date::binary-size(5), retain_date::binary-size(5), 9,
      "Test User", 6, "Test 2", 5::16-big, "ZZZZ00A", 0, 0, sent_date::binary-size(5),
      retain_date::binary-size(5), 9, "Test User", 6, "Test 1">> = rest

    logoff(context.router_pid)
  end

  test "retrieve message", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    {0, 0, _rest} = get_mailbox_page(context, 1)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 1", "Test 1")

    {1, 1,
      <<index::16-big, "ZZZZ00A", 0::16, _dates::binary-size(10), 9, "Test User", 6, "Test 1">>} =
      get_mailbox_page(context, 1)

    # check a second time to be sure the read flag isn't set
    {1, 1,
      <<^index::16-big, "ZZZZ00A", 0::16, _dates::binary-size(10), 9, "Test User", 6, "Test 1">>} =
      get_mailbox_page(context, 1)

    "Test 1" = get_message(context, index)

    # check a third time and the read flag should be set
    {1, 1,
      <<^index::16-big, "ZZZZ00A", 0::3, 1::1, 0::12, _dates::binary-size(10), 9, "Test User", 6,
        "Test 1">>} = get_mailbox_page(context, 1)

    logoff(context.router_pid)
  end

  test "check for unread messages" do
    assert Messaging.unread_messages?(%User{id: "BBBB12B"}) == false
    Messaging.send_message("AAAA12A", "John Doe", ["BBBB12B"], [], "Test", "Foo Bar Baz")
    assert Messaging.unread_messages?(%User{id: "BBBB12B"}) == true
  end

  test "delete", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    assert 0 == Message |> Repo.aggregate(:count)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 1", "Test 1")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 2", "Test 2")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 3", "Test 3")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 4", "Test 4")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 5", "Test 5")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 6", "Test 6")

    assert 6 ==  Message |> Repo.aggregate(:count)

    # Client enters mailbox - this loads the message IDs into session
    {6, 4, _rest} = get_mailbox_page(context, 1)

    # Get the actual message IDs that will be deleted (client indices 0 and 2)
    # Since messages are ordered newest first: Test 6, 5, 4, 3, 2, 1
    # Client index 0 = Test 6, Client index 2 = Test 4
    messages_before = Message
                      |> Ecto.Query.where([m], m.to_id == "AAAA12A")
                      |> Ecto.Query.order_by([m], [desc: m.sent_date, desc: m.id ])
                      |> Repo.all()

    # Get IDs of messages that should be deleted (1st and 3rd in the list)
    deleted_ids = [Enum.at(messages_before, 0).id, Enum.at(messages_before, 2).id]

    message_payload = <<
      0x04,       # delete
      2::16-big,  # delete 2 messages
      0::16-big,  # client index 0 (newest message - Test 6)
      2::16-big,  # client index 2 (Test 4)
      0xFF        # done
    >>

    Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x01>> <> message_payload
    })

    assert 4 == Message |> Repo.aggregate(:count)

    # Verify the correct messages were deleted
    assert 0 == Message |> Ecto.Query.where([m], m.id in ^deleted_ids) |> Repo.aggregate(:count)

    # Verify Test 5, 3, 2, 1 remain
    remaining = Message
                |> Ecto.Query.where([m], m.to_id == "AAAA12A")
                |> Ecto.Query.order_by([m], [desc: m.sent_date, desc: m.id ])
                |> Repo.all()

    assert 4 == length(remaining)
    assert ["Test 5", "Test 3", "Test 2", "Test 1"] == Enum.map(remaining, & &1.subject)

    logoff(context.router_pid)
  end

  test "retain", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    assert 0 == Message |> Repo.aggregate(:count)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 1", "Test 1")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 2", "Test 2")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 3", "Test 3")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 4", "Test 4")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 5", "Test 5")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 6", "Test 6")

    assert 6 == Message |> Ecto.Query.where([m], m.retain == false) |> Repo.aggregate(:count)

    # Client enters mailbox - this loads the message IDs into session
    {6, 4, _rest} = get_mailbox_page(context, 1)

    message_payload = <<
      0x05,       # retain
      3::16-big,  # retain 3 messages
      1::16-big,  # client index 1 (Test 5)
      3::16-big,  # client index 3 (Test 3)
      5::16-big,  # client index 5 (Test 1)
      0xFF        # done
    >>

    Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x01>> <> message_payload
    })

    assert 6 == Message |> Repo.aggregate(:count)
    assert 3 == Message |> Ecto.Query.where([m], m.retain == true) |> Repo.aggregate(:count)

    # Verify the correct messages were retained
    retained = Message
               |> Ecto.Query.where([m], m.to_id == "AAAA12A")
               |> Ecto.Query.where([m], m.retain == true)
               |> Ecto.Query.order_by([m], [desc: m.sent_date, desc: m.id ])
               |> Repo.all()

    assert ["Test 5", "Test 3", "Test 1"] == Enum.map(retained, & &1.subject)

    logoff(context.router_pid)
  end

  test "delete and retain", context do
    logon(context.router_pid, "AAAA12A", "foobaz", "06.03.17")

    assert 0 == Message |> Repo.aggregate(:count)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 1", "Test 1")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 2", "Test 2")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 3", "Test 3")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 4", "Test 4")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 5", "Test 5")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 6", "Test 6")

    assert 6 == Message |> Ecto.Query.where([m], m.retain == false) |> Repo.aggregate(:count)

    # Client enters mailbox - this loads the message IDs into session
    {6, 4, _rest} = get_mailbox_page(context, 1)

    # Get the actual message IDs that will be deleted (client indices 0 and 2)
    messages_before = Message
                      |> Ecto.Query.where([m], m.to_id == "AAAA12A")
                      |> Ecto.Query.order_by([m], [desc: m.sent_date, desc: m.id ])
                      |> Repo.all()

    deleted_ids = [Enum.at(messages_before, 0).id, Enum.at(messages_before, 2).id]

    message_payload = <<
      0x04,       # delete
      2::16-big,  # delete 2 messages
      0::16-big,  # client index 1 (Test 6)
      2::16-big,  # client index 3 (Test 4)
      0x05,       # retain
      3::16-big,  # retain 3 messages
      1::16-big,  # client index 2 (Test 5)
      3::16-big,  # client index 4 (Test 3)
      5::16-big,  # client index 6 (Test 1)
      0xFF        # done
    >>

    Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x01>> <> message_payload
    })

    assert 4 == Message |> Repo.aggregate(:count)
    assert 0 == Message |> Ecto.Query.where([m], m.id in ^deleted_ids) |> Repo.aggregate(:count)
    assert 3 == Message |> Ecto.Query.where([m], m.retain == true) |> Repo.aggregate(:count)

    # Verify correct messages remain and are retained
    retained = Message
               |> Ecto.Query.where([m], m.to_id == "AAAA12A")
               |> Ecto.Query.where([m], m.retain == true)
               |> Ecto.Query.order_by([m], [desc: m.sent_date, desc: m.id ])
               |> Repo.all()

    assert ["Test 5", "Test 3", "Test 1"] == Enum.map(retained, & &1.subject)

    logoff(context.router_pid)
  end

  #  test "expunge unread messages" do
  #    flunk("not yet implemented")
  #  end
  #
  #  test "expunge read messages" do
  #    flunk("not yet implemented")
  #  end
end