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

defmodule Prodigy.Server.Service.AddressBook.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase
  import Server

  import Ecto.Changeset

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{AddressBookEntry, Household, MailingList, User}
  alias Prodigy.Core.MessagingLists
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router

  require Logger

  @moduletag :capture_log

  @today DateTime.to_date(DateTime.utc_now())

  # Per-test fixture: an owner who's logged in (AAAA11A) plus a small
  # cast of recipients we can address as nicknames or mailing-list
  # members.  Same shape as the manual T1-T10 fixture - keeps the
  # test data self-explanatory when something fails.
  setup do
    seed_user("AAAA11", "AAAA11A", "JOHN", "DOE")
    seed_user("BBBB11", "BBBB11A", "BRAVO", "TESTER")
    seed_user("CCCC11", "CCCC11A", "CHARLIE", "TESTER")
    seed_user("DDDD11", "DDDD11A", "DELTA", "TESTER")
    seed_user("EEEE11", "EEEE11A", "ECHO", "TESTER")

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

  # Wrap an address-book subcode payload in the outer 0x0D opcode and
  # ship it through the router.  Strips the 16-byte Fm0 response header
  # from the binary the caller sees so per-subcode assertions stay
  # focused on the application bytes.
  defp ab_request(router_pid, subcode_payload) do
    case Router.handle_packet(router_pid, %Fm0{
           src: 0x0,
           dest: 0x00D200,
           logon_seq: 0,
           message_id: 0,
           function: Fm0.Function.APPL_0,
           payload: <<0x0D>> <> subcode_payload
         }) do
      {:ok, <<_::binary-size(16), body::binary>>} -> {:ok, body}
      {:ok} -> :ok
      other -> other
    end
  end

  # -- 0x0F: pre-screen notification -----------------------------------

  describe "0x0F pre-screen notification" do
    test "is a no-op ack with no response", %{router_pid: pid} do
      assert :ok = ab_request(pid, <<0x0F>>)
    end
  end

  # -- 0x01: list entries ---------------------------------------------

  describe "0x01 list entries" do
    test "returns an empty list when the user has no abook entries", %{router_pid: pid} do
      assert {:ok, <<0x01, 0, 0x00, 0x00, 0x00>>} = ab_request(pid, <<0x01>>)
    end

    test "returns entries ordered by nickname with entry numbers", %{router_pid: pid} do
      # Insertion order != alphabetical order: CHARLIE gets
      # entry_number=1 (added first), BRAVO gets entry_number=2.
      # The wire response orders by nickname (alphabetical), so we
      # expect to see entry numbers 2 then 1.
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      # Wire frame: 0x01 <count> 0x00 0x00 0x00 <per-entry...>
      # Per-entry: <nick_len> <nick> <entry_no::16> 0x00
      assert {:ok,
              <<0x01, 2, 0, 0, 0,
                5, "BRAVO", 2::16-big, 0,
                7, "CHARLIE", 1::16-big, 0>>} = ab_request(pid, <<0x01>>)
    end
  end

  # -- 0x02: get a specific entry (address card) ----------------------

  describe "0x02 get address card" do
    test "returns the card for an existing entry", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      # Wire frame: <user_id::7> <nick_len::16> <nick> 0 0 <list_count::16>
      assert {:ok, <<"BBBB11A", 5::16-big, "BRAVO", 0, 0, 0::16-big>>} =
               ab_request(pid, <<0x02, 1::16-big>>)
    end

    test "returns the canonical not-found response (0x0B) for an unknown entry",
         %{router_pid: pid} do
      assert {:ok, <<0x0B>>} = ab_request(pid, <<0x02, 99::16-big>>)
    end

    test "includes mailing lists the entry belongs to in the card response",
         %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])

      assert {:ok, <<"BBBB11A", 5::16-big, "BRAVO", 0, 0, 1::16-big,
                     7::16-big, "FRIENDS">>} =
               ab_request(pid, <<0x02, 1::16-big>>)
    end
  end

  # -- 0x03: add entry ------------------------------------------------

  describe "0x03 add entry" do
    test "inserts the entry and returns success (<<0>>)", %{router_pid: pid} do
      # Wire frame: 0x03 <user_id::7> <nick_len::16> <nick> 0 0 <entry_no::16>
      payload = <<0x03, "BBBB11A", 5::16-big, "BRAVO", 0, 0, 1::16-big>>
      assert {:ok, <<0x00>>} = ab_request(pid, payload)
      assert %AddressBookEntry{nickname: "BRAVO"} = Repo.get_by(AddressBookEntry, owner_id: "AAAA11A")
    end

    test "returns validation error (<<0x09>>) on duplicate target", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "FOXTROT")

      payload = <<0x03, "BBBB11A", 5::16-big, "BRAVO", 0, 0, 2::16-big>>
      assert {:ok, <<0x09>>} = ab_request(pid, payload)
    end
  end

  # -- 0x04: update entry ---------------------------------------------

  describe "0x04 update entry" do
    test "updates nickname + target and returns success (<<0x00>>)", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      # Wire frame: 0x04 <entry_no::16> <new_user_id::7> <nick_len::16> <new_nick>
      payload = <<0x04, 1::16-big, "CCCC11A", 7::16-big, "CHARLIE">>
      assert {:ok, <<0x00>>} = ab_request(pid, payload)

      assert %AddressBookEntry{nickname: "CHARLIE", target_user_id: "CCCC11A"} =
               Repo.get_by(AddressBookEntry, owner_id: "AAAA11A")
    end

    test "returns 0x09 when the new target user doesn't exist", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      payload = <<0x04, 1::16-big, "ZZZZ99A", 7::16-big, "PHANTOM">>
      assert {:ok, <<0x09>>} = ab_request(pid, payload)
    end

    test "returns 0x0B when the entry_no doesn't exist", %{router_pid: pid} do
      payload = <<0x04, 99::16-big, "BBBB11A", 5::16-big, "BRAVO">>
      assert {:ok, <<0x0B>>} = ab_request(pid, payload)
    end
  end

  # -- 0x05: delete entries (batch) -----------------------------------

  describe "0x05 delete entries" do
    test "deletes the listed entries and returns success (<<0x00>>)", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")

      # Wire frame: 0x05 <count::16> <entry_no::16>...
      payload = <<0x05, 1::16-big, 1::16-big>>
      assert {:ok, <<0x00>>} = ab_request(pid, payload)

      assert ["CHARLIE"] =
               MessagingLists.get_user_address_book("AAAA11A")
               |> Enum.map(& &1.nickname)
    end

    # The zero-deleted path returns <<0x01>> today.  When nothing was
    # deleted (e.g. the client sent a stale entry_no), there's an open
    # question whether the right response is <<0x00>> (idempotent),
    # <<0x01>> (error), or no response at all (treat delete as
    # SEND-only the way create_mailing_list became).  Captured here as
    # the current behavior; flip when the right semantic is decided.
    test "returns 0x01 when no entries match the listed entry_nos", %{router_pid: pid} do
      payload = <<0x05, 1::16-big, 99::16-big>>
      assert {:ok, <<0x01>>} = ab_request(pid, payload)
    end
  end

  # -- 0x06: list mailing lists ---------------------------------------

  describe "0x06 list mailing lists" do
    test "returns max_members + list count + can_create header with empty body",
         %{router_pid: pid} do
      # Wire frame: <max_members> <list_count> <can_create> 0x00 0x00 <per-list...>
      # No lists -> body empty; can_create=1 (under cap)
      assert {:ok, <<15, 0, 1, 0x00, 0x00>>} = ab_request(pid, <<0x06>>)
    end

    test "lists each mailing list with member count and list_number", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])

      # Per-list: <name_len> <name> <member_count::16> <list_number::16> 0x00
      assert {:ok, <<15, 1, 1, 0, 0,
                     7, "FRIENDS", 1::16-big, 1::16-big, 0>>} =
               ab_request(pid, <<0x06>>)
    end
  end

  # -- 0x07: get list members -----------------------------------------

  describe "0x07 get list members" do
    test "returns the members of the requested list", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1, 2])

      # Wire frame: 0x00 <member_count> 0x00 <max_members> 0x00 <per-member...>
      # Per-member: <nick_len> <nick> <entry_no::16> 0x00
      assert {:ok, <<0, 2, 0, 15, 0, _members::binary>>} =
               ab_request(pid, <<0x07, 1::16-big>>)
    end

    test "returns the empty-list response when the list_number is unknown",
         %{router_pid: pid} do
      assert {:ok, <<0, 0, 0, _max_members, 0>>} = ab_request(pid, <<0x07, 99::16-big>>)
    end
  end

  # -- 0x08: get address-book entries NOT in the current list ---------

  describe "0x08 list non-members for add-members flow" do
    test "returns entries that are not members of the current list", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])

      # 0x07 sets context.current_list_number; 0x08 reads it.
      assert {:ok, _members} = ab_request(pid, <<0x07, 1::16-big>>)

      assert {:ok, <<0x01, 1, 0, 0, 0,
                     7, "CHARLIE", 2::16-big, 0>>} =
               ab_request(pid, <<0x08>>)
    end
  end

  # -- 0x09: add members to list --------------------------------------

  describe "0x09 add members to list" do
    test "adds the listed members and returns success (<<0>>)", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])

      # Wire frame: 0x09 <list_no::16> <count::16> <entry_no::16>...
      assert {:ok, <<0>>} = ab_request(pid, <<0x09, 1::16-big, 1::16-big, 2::16-big>>)

      members = MessagingLists.get_mailing_list_members("AAAA11A", 1).members
      assert ["BRAVO", "CHARLIE"] = Enum.map(members, & &1.nickname) |> Enum.sort()
    end

    test "returns <<0x01>> when the list_number is unknown", %{router_pid: pid} do
      assert {:ok, <<0x01>>} = ab_request(pid, <<0x09, 99::16-big, 1::16-big, 1::16-big>>)
    end
  end

  # -- 0x0A: remove members from list ---------------------------------

  describe "0x0A remove members from list" do
    test "removes the listed members and returns success (<<0>>)", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1, 2])

      assert {:ok, <<0>>} = ab_request(pid, <<0x0A, 1::16-big, 1::16-big, 1::16-big>>)

      members = MessagingLists.get_mailing_list_members("AAAA11A", 1).members
      assert ["CHARLIE"] = Enum.map(members, & &1.nickname)
    end

    test "returns <<0x01>> when the list_number is unknown", %{router_pid: pid} do
      assert {:ok, <<0x01>>} = ab_request(pid, <<0x0A, 99::16-big, 1::16-big, 1::16-big>>)
    end
  end

  # -- 0x0B: list entries for create-mailing-list flow ----------------

  describe "0x0B list entries for create-list flow" do
    test "returns the full address book (same shape as 0x01)", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      assert {:ok, <<0x01, 1, 0, 0, 0,
                     5, "BRAVO", 1::16-big, 0>>} =
               ab_request(pid, <<0x0B>>)
    end
  end

  # -- 0x0C: create mailing list (SEND-only wire pattern) -------------

  describe "0x0C create mailing list" do
    # MSZA028X.src on the client SENDs this opcode without a matching
    # RECEIVE; sending ANY response (success OR error) trips OMCM 10
    # "out of sequence" on the client.  So both branches return :ok
    # (atom) which makes Router emit no response binary.  We assert
    # the absence of a response AND the DB-side effect.

    test "creates the list with no response on the wire", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")

      # Wire frame: 0x0C <name_len::16> <name> <list_no::16> <member_count::16> <entry_no::16>...
      payload = <<0x0C, 7::16-big, "FRIENDS", 1::16-big, 2::16-big, 1::16-big, 2::16-big>>
      assert :ok = ab_request(pid, payload)

      assert [%MailingList{name: "FRIENDS"}] = MessagingLists.get_user_mailing_lists("AAAA11A")
    end

    test "no response on the wire even when creation fails (would trip OMCM 10)",
         %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])

      # Duplicate name -> changeset failure -> still no wire response.
      payload = <<0x0C, 7::16-big, "FRIENDS", 2::16-big, 1::16-big, 1::16-big>>
      assert :ok = ab_request(pid, payload)

      # No second list created
      assert 1 = length(MessagingLists.get_user_mailing_lists("AAAA11A"))
    end
  end

  # -- 0x0D: delete mailing lists (batch) -----------------------------

  describe "0x0D delete mailing lists" do
    test "deletes the listed lists and emits no wire response", %{router_pid: pid} do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "OTHER", 2, [1])

      # Wire frame: 0x0D <count::16> <list_no::16>...
      payload = <<0x0D, 1::16-big, 1::16-big>>
      assert :ok = ab_request(pid, payload)

      assert ["OTHER"] =
               MessagingLists.get_user_mailing_lists("AAAA11A")
               |> Enum.map(& &1.name)
    end
  end
end
