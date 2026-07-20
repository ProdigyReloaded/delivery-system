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

defmodule Prodigy.Server.Service.Messaging.RecipientResolution.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Server

  import Ecto.Changeset

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, Message, User}
  alias Prodigy.Core.MessagingLists
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router

  require Logger

  @moduletag :capture_log

  @today DateTime.to_date(DateTime.utc_now())

  # End-to-end fixture: mirrors the S1-S9 setup from the manual T1-T10
  # exercise.  An AAAA11A sender, seven recipients, six address-book
  # nicknames, three mailing lists, both collision pairs in place
  # (nickname BRAVO + list BRAVO, nickname TEAM + list TEAM).  Keeps
  # the conversation trail in sync with the test inputs.
  setup do
    seed_user("AAAA11", "AAAA11A", "JOHN", "DOE")
    seed_user("BBBB11", "BBBB11A", "BRAVO", "TESTER")
    seed_user("CCCC11", "CCCC11A", "CHARLIE", "TESTER")
    seed_user("DDDD11", "DDDD11A", "DELTA", "TESTER")
    seed_user("EEEE11", "EEEE11A", "ECHO", "TESTER")
    seed_user("FFFF11", "FFFF11A", "FOXTROT", "TESTER")
    seed_user("GGGG11", "GGGG11A", "GOLF", "TESTER")
    seed_user("HHHH11", "HHHH11A", "HOTEL", "TESTER")

    {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
    {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
    {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "DDDD11A", "DELTA")
    {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "EEEE11A", "ECHO")
    {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "FFFF11A", "FOXTROT")
    {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "GGGG11A", "TEAM")

    {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1, 2])
    {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "TEAM", 2, [2, 3, 4])
    {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "BRAVO", 3, [3, 4])

    {:ok, router_pid} = GenServer.start_link(Router, nil)
    logon(router_pid, "AAAA11A", "foobaz", "06.03.17")

    on_exit(fn -> ensure_logoff(router_pid) end)

    [router_pid: router_pid]
  end

  defp seed_user(hh_id, user_id, first, last) do
    %Household{id: hh_id, enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{
        id: user_id,
        profile: %{"015F" => first, "015E" => last},
        date_enrolled: @today
      }
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()
  end

  # Build the inner messaging-send wire payload (everything that
  # follows the 0x01 service-leading byte and 0x02 SEND subcode).
  defp send_payload(to_ids, to_others, subject, body) do
    count = length(to_ids)
    ids_bin = Enum.reduce(to_ids, <<>>, fn id, acc -> acc <> id end)

    others_bin =
      Enum.reduce(to_others, <<>>, fn s, acc ->
        acc <> <<byte_size(s)>> <> s
      end)

    <<
      0x01,
      0x02,
      count::16-big,
      ids_bin::binary,
      byte_size(others_bin)::16-big,
      others_bin::binary,
      byte_size(subject),
      subject::binary,
      byte_size(body)::16-big,
      body::binary
    >>
  end

  defp send_via_router(router_pid, payload) do
    Router.handle_packet(router_pid, %Fm0{
      src: 0x0,
      dest: 0x00D200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x01>> <> payload
    })
  end

  # Convenience: send + fetch all Message rows in insertion order.
  defp send_and_collect(router_pid, to_ids, to_others, subject, body) do
    send_via_router(router_pid, send_payload(to_ids, to_others, subject, body))
    Repo.all(from(m in Message, order_by: m.id))
  end

  # Decode a bounce row's `contents` into its wire-format sections.
  # See send_bounce/4 in Messaging service for the producing side.
  defp decode_bounce_contents(contents) do
    <<flags, count, rest::binary>> = contents
    fixed_size = count * 7
    <<fixed_bin::binary-size(fixed_size), rest::binary>> = rest
    <<var_len::16-big, var_bin::binary-size(var_len), rest::binary>> = rest
    <<body_len::16-big, body::binary-size(body_len)>> = rest

    fixed_ids = for <<id::binary-size(7) <- fixed_bin>>, do: id

    variable_extras =
      Stream.unfold(var_bin, fn
        <<>> -> nil
        <<n, txt::binary-size(n), more::binary>> -> {txt, more}
      end)
      |> Enum.to_list()

    %{flags: flags, fixed_ids: fixed_ids, variable_extras: variable_extras, body: body}
  end

  # -- T1 -- single nickname (also the implicit collision-with-list-BRAVO test) --

  test "T1: single nickname BRAVO delivers to BBBB11A only, no bounce",
       %{router_pid: pid} do
    [msg] = send_and_collect(pid, [], ["BRAVO"], "T1", "hello bravo")

    assert %Message{
             from_id: "AAAA11A",
             to_id: "BBBB11A",
             subject: "T1",
             bounce: false,
             contents: "hello bravo"
           } = msg

    # The list named BRAVO (DDDD11A + EEEE11A) is intentionally NOT
    # expanded - nickname precedence wins.  Asserted via the single-row
    # match above; if any other delivery occurred the [msg] match
    # would fail.
  end

  # -- T2 -- list expansion ------------------------------------------

  test "T2: list FRIENDS expands to BRAVO + CHARLIE", %{router_pid: pid} do
    msgs = send_and_collect(pid, [], ["FRIENDS"], "T2", "hello friends")

    to_ids = msgs |> Enum.map(& &1.to_id) |> Enum.sort()
    assert ["BBBB11A", "CCCC11A"] = to_ids
    assert Enum.all?(msgs, &(&1.bounce == false))
    assert Enum.all?(msgs, &(&1.subject == "T2"))
  end

  # T3 collapses into T1 (the BRAVO list already exists at the time T1
  # runs, so T1 IS the collision test).

  # -- T4 -- the reverse collision (TEAM nickname over TEAM list) ----

  test "T4: nickname TEAM wins over list TEAM (delivers to GGGG11A only)",
       %{router_pid: pid} do
    [msg] = send_and_collect(pid, [], ["TEAM"], "T4", "hello team")

    assert %Message{to_id: "GGGG11A", subject: "T4", bounce: false} = msg
  end

  # -- T5 -- literal Prodigy ID --------------------------------------

  test "T5: literal HHHH11A resolves through user-exists check",
       %{router_pid: pid} do
    [msg] = send_and_collect(pid, ["HHHH11A"], [], "T5", "hello hotel")

    assert %Message{to_id: "HHHH11A", subject: "T5", bounce: false} = msg
  end

  # -- T6 -- multi-recipient dedup -----------------------------------

  test "T6: BRAVO + DELTA + FRIENDS dedup to 3 unique deliveries",
       %{router_pid: pid} do
    msgs = send_and_collect(pid, [], ["BRAVO", "DELTA", "FRIENDS"], "T6", "hello team")

    to_ids = msgs |> Enum.map(& &1.to_id) |> Enum.sort()
    # BRAVO appears once (deduped from nickname-path + FRIENDS-path);
    # CHARLIE from FRIENDS; DELTA from the nickname.  Three rows total.
    assert ["BBBB11A", "CCCC11A", "DDDD11A"] = to_ids
    assert Enum.all?(msgs, &(&1.bounce == false))
  end

  # -- T7 -- non-existent nickname -> bounce in variable_extras ------

  test "T7: NOSUCH lands in variable_extras and produces a bounce row",
       %{router_pid: pid} do
    [bounce] = send_and_collect(pid, [], ["NOSUCH"], "T7", "hello phantom")

    assert %Message{
             from_id: "HELP99A",
             from_name: "PRODIGY SERVICE",
             to_id: "AAAA11A",
             subject: "Return To Sender",
             bounce: true
           } = bounce

    decoded = decode_bounce_contents(bounce.contents)
    # Sequence-99 selector for the v2-synth MSZB0R2S.D99 template
    assert 0x63 = decoded.flags
    assert [] = decoded.fixed_ids
    assert ["NOSUCH"] = decoded.variable_extras
    # Body starts with the 40-col blank-line of the metadata prefix
    assert <<"                                        ", _rest::binary>> = decoded.body
  end

  # -- T8 -- non-existent Prodigy ID -> bounce in fixed_ids ----------

  test "T8: ZZZZ99A is Prodigy-ID-shaped, lands in fixed_ids, produces a bounce",
       %{router_pid: pid} do
    [bounce] = send_and_collect(pid, ["ZZZZ99A"], [], "T8", "hello phantom")

    assert %Message{from_id: "HELP99A", bounce: true} = bounce

    decoded = decode_bounce_contents(bounce.contents)
    assert ["ZZZZ99A"] = decoded.fixed_ids
    assert [] = decoded.variable_extras
  end

  # -- T9 -- mixed valid + invalid -> one delivery + one bounce ------

  test "T9: BRAVO + NOSUCH produces both a real delivery and a bounce",
       %{router_pid: pid} do
    msgs = send_and_collect(pid, [], ["BRAVO", "NOSUCH"], "T9", "hello mix")

    deliveries = Enum.filter(msgs, &(&1.bounce == false))
    bounces = Enum.filter(msgs, & &1.bounce)

    assert [%Message{to_id: "BBBB11A", subject: "T9"}] = deliveries
    assert [%Message{to_id: "AAAA11A", subject: "Return To Sender"}] = bounces

    decoded = decode_bounce_contents(hd(bounces).contents)
    assert ["NOSUCH"] = decoded.variable_extras
  end

  # -- T10 -- self-send is legitimate --------------------------------

  test "T10: sending to one's own ID delivers a real inbox row, no bounce",
       %{router_pid: pid} do
    [msg] = send_and_collect(pid, ["AAAA11A"], [], "T10", "note to self")

    assert %Message{from_id: "AAAA11A", to_id: "AAAA11A", subject: "T10", bounce: false} = msg
  end

  # -- T11 -- multiple fixed id slots resolved in one batched query --
  # Exercises verify_fixed_ids/1 with several slots at once: two valid
  # (one repeated), one missing.  The valid ids dedup to two deliveries;
  # the missing id produces a single fixed-id bounce.

  test "T11: fixed-id slots resolve in a batch - valid dedup, missing bounces",
       %{router_pid: pid} do
    msgs =
      send_and_collect(pid, ["BBBB11A", "CCCC11A", "ZZZZ99A", "BBBB11A"], [], "T11", "hi batch")

    deliveries = msgs |> Enum.filter(&(&1.bounce == false))
    bounces = Enum.filter(msgs, & &1.bounce)

    # BBBB11A appears twice in the fixed slots but delivers once.
    assert ["BBBB11A", "CCCC11A"] = deliveries |> Enum.map(& &1.to_id) |> Enum.sort()
    assert Enum.all?(deliveries, &(&1.subject == "T11"))

    assert [%Message{to_id: "AAAA11A", subject: "Return To Sender"}] = bounces
    decoded = decode_bounce_contents(hd(bounces).contents)
    assert ["ZZZZ99A"] = decoded.fixed_ids
  end
end
