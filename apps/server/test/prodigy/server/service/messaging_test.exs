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

defmodule Prodigy.Server.Service.Messaging.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Ecto.Changeset

  alias Prodigy.Server.Router
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Service.Messaging
  alias Prodigy.Core.Data.{User, Household, Message}
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

    # TODO could we just use the router for one single test, or should we use it for all?
    {:ok, router_pid} = GenServer.start_link(Router, nil)

    # would like to put logon here, and logoff in a callback, but there is only on_exit which is called after
    # the Router is terminated by ExUnit, which would mean the logoff would get called after the Repo supervisor is
    # shutdown

    [router_pid: router_pid]
  end

  defp logon(context) do
    Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0x2200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x1, "AAAA12A", 6, "foobaz", "06.03.17">>
    })
  end

  defp logoff(context) do
    Router.handle_packet(context.router_pid, %Fm0{
      src: 0x0,
      dest: 0xD201,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0
    })
  end

  test "send message", context do
    logon(context)

    messages = Message
               |> Repo.all()

    assert(length(messages) == 0)

    message_payload = <<
      0x01,
      0x02,           # indicates "Send a message" to the messaging service
      2::16-big,      # send to 2 user ids
      "BBBB12B",
      "CCCC12C",
      21::16-big,     # length of all the "others" to follow
      8,              # length of "JOHN DOE"
      "JOHN DOE",
      11,             # length of "SALLY SMITH"
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
      payload: << 0x01 >> <> message_payload
    })

    messages = Message
               |> Repo.all()

    # there should now be two messages, one to BBBB12B and one to CCCC12C
    assert(length(messages) == 2)

    logoff(context)
  end

#  test "retrieve mailbox" do
#    flunk("not yet implemented")
#  end

#  test "retrieve message" do
#    flunk("not yet implemented")
#  end
#
  test "check for unread messages" do
    assert Messaging.unread_messages?(%User{id: "BBBB12B"}) == false
    Messaging.send_message("AAAA12A", "John Doe", ["BBBB12B"], [], "Test", "Foo Bar Baz")
    assert Messaging.unread_messages?(%User{id: "BBBB12B"}) == true
  end
#
#  test "expunge unread messages" do
#    flunk("not yet implemented")
#  end
#
#  test "expunge read messages" do
#    flunk("not yet implemented")
#  end
end