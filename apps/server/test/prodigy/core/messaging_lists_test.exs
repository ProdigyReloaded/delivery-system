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

defmodule Prodigy.Core.MessagingLists.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase

  import Ecto.Changeset

  alias Prodigy.Core.Data.Repo

  alias Prodigy.Core.Data.Service.{
    AddressBookEntry,
    Household,
    MailingList,
    MailingListMember,
    User
  }

  alias Prodigy.Core.MessagingLists

  @moduletag :capture_log

  @today DateTime.to_date(DateTime.utc_now())

  # Fixture: an owner (AAAA11A) and a handful of target users that
  # the tests use as address-book / mailing-list participants.  The
  # naming mirrors the manual T1-T10 scaffolding from the parent
  # session - BRAVO/CHARLIE/DELTA/ECHO/FOXTROT - so cross-referencing
  # is easy when something fails.
  setup do
    seed_user("AAAA11", "AAAA11A", "JOHN", "DOE")
    seed_user("BBBB11", "BBBB11A", "BRAVO", "TESTER")
    seed_user("CCCC11", "CCCC11A", "CHARLIE", "TESTER")
    seed_user("DDDD11", "DDDD11A", "DELTA", "TESTER")
    seed_user("EEEE11", "EEEE11A", "ECHO", "TESTER")
    seed_user("FFFF11", "FFFF11A", "FOXTROT", "TESTER")
    :ok
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

  # -- Address book CRUD ----------------------------------------------

  describe "add_address_book_entry/3" do
    test "inserts a new entry with the next available entry_number" do
      assert {:ok, %AddressBookEntry{entry_number: 1, nickname: "BRAVO"}} =
               MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      assert {:ok, %AddressBookEntry{entry_number: 2, nickname: "CHARLIE"}} =
               MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
    end

    test "returns {:error, changeset} when the target is already addressed under another nickname" do
      assert {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      assert {:error, %Ecto.Changeset{} = cs} =
               MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "ALPHA")

      # The unique constraint that fires is (owner_id, target_user_id);
      # Ecto surfaces it as an error on owner_id.
      assert cs.errors[:owner_id] != nil or cs.errors[:target_user_id] != nil
    end
  end

  describe "get_user_address_book/1" do
    test "returns rows ordered by nickname with target_user preloaded" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "DDDD11A", "DELTA")

      entries = MessagingLists.get_user_address_book("AAAA11A")

      assert ["BRAVO", "CHARLIE", "DELTA"] = Enum.map(entries, & &1.nickname)
      assert Enum.all?(entries, &match?(%User{}, &1.target_user))
    end

    test "returns empty list when the owner has no entries" do
      assert [] = MessagingLists.get_user_address_book("AAAA11A")
    end
  end

  describe "get_address_book_entry/2" do
    test "returns the entry with target_user preloaded when entry_number exists" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      assert %AddressBookEntry{nickname: "BRAVO", target_user: %User{id: "BBBB11A"}} =
               MessagingLists.get_address_book_entry("AAAA11A", 1)
    end

    test "returns nil for an unknown entry_number" do
      assert nil == MessagingLists.get_address_book_entry("AAAA11A", 99)
    end
  end

  describe "update_address_book_entry/3" do
    test "updates the nickname on an existing entry" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      assert {:ok, %AddressBookEntry{nickname: "BUDDY"}} =
               MessagingLists.update_address_book_entry("AAAA11A", 1, %{
                 nickname: "BUDDY",
                 target_user_id: "BBBB11A"
               })
    end

    test "returns {:error, :not_found} for an unknown entry_number" do
      assert {:error, :not_found} =
               MessagingLists.update_address_book_entry("AAAA11A", 99, %{nickname: "X"})
    end
  end

  describe "delete_address_book_entry/2" do
    test "deletes the entry and cascades through mailing_list_members" do
      # Set up: an entry, plus a list whose only member is that entry.
      # After delete, the entry should be gone AND the member row that
      # referenced it should also be gone (cascade via the FK's ON
      # DELETE CASCADE).
      {:ok, entry} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, %MailingList{id: list_id}} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])

      assert Repo.get_by(MailingListMember,
               mailing_list_id: list_id,
               address_book_entry_id: entry.id
             )

      assert {:ok, _} = MessagingLists.delete_address_book_entry("AAAA11A", 1)

      assert nil == MessagingLists.get_address_book_entry("AAAA11A", 1)

      refute Repo.get_by(MailingListMember,
               mailing_list_id: list_id,
               address_book_entry_id: entry.id
             )
    end

    test "returns {:error, :not_found} for an unknown entry_number" do
      assert {:error, :not_found} = MessagingLists.delete_address_book_entry("AAAA11A", 99)
    end
  end

  describe "get_next_entry_number/1" do
    test "returns 1 when the address book is empty" do
      assert 1 = MessagingLists.get_next_entry_number("AAAA11A")
    end

    test "returns max+1 when there are gaps below the cap" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      assert 2 = MessagingLists.get_next_entry_number("AAAA11A")
    end

    test "finds the first gap when slot 50 is occupied" do
      # Manually seed entry_number=50 (a hole at every value 1..49)
      # and confirm get_next_entry_number returns the lowest unused
      # slot.
      %AddressBookEntry{}
      |> AddressBookEntry.changeset(%{
        owner_id: "AAAA11A",
        target_user_id: "BBBB11A",
        nickname: "BRAVO",
        entry_number: 50
      })
      |> Repo.insert!()

      assert 1 = MessagingLists.get_next_entry_number("AAAA11A")
    end
  end

  # -- Mailing list CRUD ----------------------------------------------

  describe "create_mailing_list/4" do
    test "inserts list + member rows atomically" do
      {:ok, _e1} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _e2} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")

      assert {:ok, %MailingList{name: "FRIENDS", list_number: 1}} =
               MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1, 2])

      # Both members in place
      members = MessagingLists.get_mailing_list_members("AAAA11A", 1).members
      assert 2 = length(members)
      assert ["BRAVO", "CHARLIE"] = Enum.map(members, & &1.nickname) |> Enum.sort()
    end

    test "rolls back when the list changeset is invalid (duplicate name)" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])

      assert {:error, %Ecto.Changeset{}} =
               MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 2, [1])

      # Exactly one list still exists; no orphaned member rows from
      # the failed insertion.
      assert 1 = length(MessagingLists.get_user_mailing_lists("AAAA11A"))
    end
  end

  describe "delete_mailing_list/2" do
    test "removes the list and its members" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, %MailingList{id: list_id}} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])

      assert :ok = MessagingLists.delete_mailing_list("AAAA11A", 1)

      assert nil == Repo.get(MailingList, list_id)
      assert [] = Repo.all(MailingListMember, mailing_list_id: list_id)
    end

    test "returns {:error, :not_found} for an unknown list_number" do
      assert {:error, :not_found} = MessagingLists.delete_mailing_list("AAAA11A", 99)
    end
  end

  describe "get_user_mailing_lists/1" do
    test "returns rows ordered by list_number with members preloaded" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "ZETA", 2, [1])
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "ALPHA", 1, [1])

      lists = MessagingLists.get_user_mailing_lists("AAAA11A")
      assert ["ALPHA", "ZETA"] = Enum.map(lists, & &1.name)
      assert Enum.all?(lists, &is_list(&1.members))
    end
  end

  describe "add_members_to_list/3" do
    test "adds the listed entries; duplicates are no-ops via on_conflict" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])

      assert :ok = MessagingLists.add_members_to_list("AAAA11A", 1, [2])
      assert 2 = length(MessagingLists.get_mailing_list_members("AAAA11A", 1).members)

      # Re-adding the same member is a no-op (on_conflict: :nothing)
      assert :ok = MessagingLists.add_members_to_list("AAAA11A", 1, [2])
      assert 2 = length(MessagingLists.get_mailing_list_members("AAAA11A", 1).members)
    end

    test "returns {:error, :list_not_found} when list_number is unknown" do
      assert {:error, :list_not_found} = MessagingLists.add_members_to_list("AAAA11A", 99, [1])
    end
  end

  describe "remove_members_from_list/3" do
    test "removes only the listed entries; others survive" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1, 2])

      assert :ok = MessagingLists.remove_members_from_list("AAAA11A", 1, [1])

      members = MessagingLists.get_mailing_list_members("AAAA11A", 1).members
      assert ["CHARLIE"] = Enum.map(members, & &1.nickname)
    end

    test "returns {:error, :list_not_found} when list_number is unknown" do
      assert {:error, :list_not_found} =
               MessagingLists.remove_members_from_list("AAAA11A", 99, [1])
    end
  end

  describe "get_address_book_not_in_list/2" do
    test "returns entries that are NOT members of the given list" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "DDDD11A", "DELTA")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1, 2])

      non_members = MessagingLists.get_address_book_not_in_list("AAAA11A", 1)
      assert ["DELTA"] = Enum.map(non_members, & &1.nickname)
    end

    test "returns the full address book when the list doesn't exist" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      assert ["BRAVO"] = MessagingLists.get_address_book_not_in_list("AAAA11A", 99)
                        |> Enum.map(& &1.nickname)
    end
  end

  describe "get_lists_for_entry/2" do
    test "returns all lists that contain the given entry" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "ZETA", 2, [1])
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "ALPHA", 1, [1])

      lists = MessagingLists.get_lists_for_entry("AAAA11A", 1)
      assert ["ALPHA", "ZETA"] = Enum.map(lists, & &1.name)
    end

    test "returns [] for an unknown entry_number" do
      assert [] = MessagingLists.get_lists_for_entry("AAAA11A", 99)
    end
  end

  describe "get_max_members_per_list/1" do
    test "returns the current cap" do
      assert 15 = MessagingLists.get_max_members_per_list("AAAA11A")
    end
  end

  describe "can_create_mailing_list?/1" do
    test "true when under the cap" do
      assert MessagingLists.can_create_mailing_list?("AAAA11A")
    end

    test "false when at the cap" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      for n <- 1..10 do
        {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "L#{n}", n, [1])
      end

      refute MessagingLists.can_create_mailing_list?("AAAA11A")
    end
  end

  describe "get_next_list_number/1" do
    test "returns 1 when the user has no lists" do
      assert 1 = MessagingLists.get_next_list_number("AAAA11A")
    end

    test "returns max+1 once lists exist" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1])
      assert 2 = MessagingLists.get_next_list_number("AAAA11A")
    end
  end

  # -- Recipient resolution ------------------------------------------
  #
  # These tests exercise the precedence rule directly at the context
  # level.  The end-to-end SEND path through internal_send_message
  # gets its own integration test in messaging_recipient_resolution_test.

  describe "resolve_recipients/2" do
    test "empty input returns empty {resolved, failed}" do
      assert {[], []} = MessagingLists.resolve_recipients("AAAA11A", [])
    end

    test "nickname resolves to the target user_id" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")

      assert {["BBBB11A"], []} =
               MessagingLists.resolve_recipients("AAAA11A", ["BRAVO"])
    end

    test "mailing-list name expands to all member target user_ids" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1, 2])

      {resolved, []} = MessagingLists.resolve_recipients("AAAA11A", ["FRIENDS"])
      assert ["BBBB11A", "CCCC11A"] = Enum.sort(resolved)
    end

    test "nickname wins when the same string is both a nickname and a list name" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "TEAM")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "DDDD11A", "DELTA")
      # Distinct list name to avoid the (owner_id, name) unique
      # constraint on the abook side - we want a list whose NAME is
      # TEAM, so we have to assign a list_number, but the nickname
      # already owns "TEAM" for this owner.
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "TEAM", 1, [2, 3])

      assert {["BBBB11A"], []} =
               MessagingLists.resolve_recipients("AAAA11A", ["TEAM"])
    end

    test "valid literal Prodigy-ID-shaped string with existing user goes to resolved" do
      assert {["BBBB11A"], []} =
               MessagingLists.resolve_recipients("AAAA11A", ["BBBB11A"])
    end

    test "Prodigy-ID-shaped string for a non-existent user goes to failed" do
      assert {[], ["ZZZZ99A"]} =
               MessagingLists.resolve_recipients("AAAA11A", ["ZZZZ99A"])
    end

    test "non-Prodigy-ID free-form string with no nickname/list match goes to failed" do
      assert {[], ["NOSUCH"]} =
               MessagingLists.resolve_recipients("AAAA11A", ["NOSUCH"])
    end

    test "dedup: same target reached via multiple paths collapses to one resolved entry" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1, 2])

      # BRAVO appears via the nickname AND as a FRIENDS member; should
      # resolve to one delivery to BBBB11A.
      {resolved, []} = MessagingLists.resolve_recipients("AAAA11A", ["BRAVO", "FRIENDS"])
      assert ["BBBB11A", "CCCC11A"] = Enum.sort(resolved)
    end

    test "whitespace-only and empty-string candidates are filtered out" do
      assert {[], []} = MessagingLists.resolve_recipients("AAAA11A", ["", "  ", "\t"])
    end

    test "repeated mailing-list name is expanded once (cycle/repeat guard)" do
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "BBBB11A", "BRAVO")
      {:ok, _} = MessagingLists.add_address_book_entry("AAAA11A", "CCCC11A", "CHARLIE")
      {:ok, _} = MessagingLists.create_mailing_list("AAAA11A", "FRIENDS", 1, [1, 2])

      # The same list name appearing twice must not re-expand (the seen-list
      # guard skips the second sighting); result is still the deduped members.
      {resolved, []} =
        MessagingLists.resolve_recipients("AAAA11A", ["FRIENDS", "FRIENDS"])

      assert ["BBBB11A", "CCCC11A"] = Enum.sort(resolved)
    end
  end
end
