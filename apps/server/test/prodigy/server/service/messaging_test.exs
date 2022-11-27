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
    {1, 1, _rest} = get_mailbox_page(context, 1)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 2", "Test 2")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 3", "Test 3")
    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 4", "Test 4")
    {4, 4, _rest} = get_mailbox_page(context, 1)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 5", "Test 5")
    {5, 4, _rest} = get_mailbox_page(context, 1)

    Messaging.send_message("ZZZZ00A", "Test User", ["AAAA12A"], [], "Test 6", "Test 6")
    {6, 2, rest} = get_mailbox_page(context, 2)

    # make sure the messages on page 2 are as expected

    # Timex mock above not working as expected; will ignore values for now
    # sent_date = Timex.format!(epoch(), "{0M}/{0D}")
    # u retain_date = Timex.format!(Timex.shift(epoch(), days: 14), "{0M}/{0D}")
    <<5::16-big, "ZZZZ00A", 0, 0, sent_date::binary-size(5), retain_date::binary-size(5), 9,
      "Test User", 6, "Test 5", 6::16-big, "ZZZZ00A", 0, 0, sent_date::binary-size(5),
      retain_date::binary-size(5), 9, "Test User", 6, "Test 6">> = rest

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

  #
  #  test "delete & retain" do
  #    flunk("not yet implemented")
  #  end
  #
  #  test "expunge unread messages" do
  #    flunk("not yet implemented")
  #  end
  #
  #  test "expunge read messages" do
  #    flunk("not yet implemented")
  #  end
end
