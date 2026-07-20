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

defmodule Prodigy.Core.Data.Service.MailingList.Test do
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

  @moduletag :capture_log

  @today DateTime.to_date(DateTime.utc_now())

  # Two users + a single abook entry for the owner.  Enough state for
  # both the MailingList tests (which only need an owner_id that
  # resolves to a real User) and the MailingListMember tests (which
  # additionally need a list to belong to and an abook entry to refer
  # to).
  setup do
    %Household{id: "AAAA11", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA11A", profile: %{"015F" => "JOHN", "015E" => "DOE"}, date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()

    %Household{id: "BBBB11", enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: "BBBB11A", profile: %{"015F" => "BRAVO", "015E" => "TESTER"}, date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()

    abook_entry =
      %AddressBookEntry{}
      |> AddressBookEntry.changeset(%{
        owner_id: "AAAA11A",
        target_user_id: "BBBB11A",
        nickname: "BRAVO",
        entry_number: 1
      })
      |> Repo.insert!()

    {:ok, abook_entry: abook_entry}
  end

  defp valid_list_attrs(overrides) do
    Map.merge(
      %{
        owner_id: "AAAA11A",
        name: "FRIENDS",
        list_number: 1,
        max_members: 15
      },
      overrides
    )
  end

  defp list_changeset(overrides \\ %{}) do
    MailingList.changeset(%MailingList{}, valid_list_attrs(overrides))
  end

  describe "MailingList changeset/2 - required fields" do
    test "valid with all required fields present" do
      cs = list_changeset()
      assert cs.valid?
      assert {:ok, %MailingList{}} = Repo.insert(cs)
    end

    test "missing owner_id is invalid" do
      cs = list_changeset(%{owner_id: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:owner_id]
    end

    test "missing name is invalid" do
      cs = list_changeset(%{name: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:name]
    end

    test "missing list_number is invalid" do
      cs = list_changeset(%{list_number: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:list_number]
    end
  end

  describe "MailingList changeset/2 - name format and length" do
    test "rejects name longer than 19 characters" do
      cs = list_changeset(%{name: String.duplicate("X", 20)})
      refute cs.valid?
      assert {_, [count: 19, validation: :length, kind: :max, type: :string]} =
               cs.errors[:name]
    end

    test "accepts name at the 19-character limit" do
      cs = list_changeset(%{name: String.duplicate("X", 19)})
      assert cs.valid?
    end

    # Same Prodigy-ID-shape rule as AddressBookEntry: refuse anything a
    # client could mistake for a real subscriber ID, regardless of
    # what a non-conforming client tries to send.
    test "rejects name matching the Prodigy-ID format (uppercase)" do
      cs = list_changeset(%{name: "AAAA11A"})
      refute cs.valid?
      assert {"cannot look like a Prodigy ID", _} = cs.errors[:name]
    end

    test "rejects name matching the Prodigy-ID format (lowercase)" do
      cs = list_changeset(%{name: "aaaa11a"})
      refute cs.valid?
      assert {"cannot look like a Prodigy ID", _} = cs.errors[:name]
    end
  end

  describe "MailingList changeset/2 - max_members range" do
    test "max_members = 0 is invalid" do
      cs = list_changeset(%{max_members: 0})
      refute cs.valid?
      assert {_, [validation: :number, kind: :greater_than, number: 0]} =
               cs.errors[:max_members]
    end

    test "max_members = 1 is valid (lower boundary)" do
      assert list_changeset(%{max_members: 1}).valid?
    end

    test "max_members = 20 is valid (upper boundary)" do
      assert list_changeset(%{max_members: 20}).valid?
    end

    test "max_members = 21 is invalid" do
      cs = list_changeset(%{max_members: 21})
      refute cs.valid?

      assert {_, [validation: :number, kind: :less_than_or_equal_to, number: 20]} =
               cs.errors[:max_members]
    end
  end

  describe "MailingList changeset/2 - unique constraints" do
    test "duplicate (owner_id, list_number) is rejected" do
      assert {:ok, _} = Repo.insert(list_changeset())

      {:error, cs} =
        # Same owner + same list_number, different name.
        list_changeset(%{name: "TEAM"})
        |> Repo.insert()

      assert {"has already been taken", _} = cs.errors[:owner_id]
    end

    test "duplicate (owner_id, name) is rejected" do
      assert {:ok, _} = Repo.insert(list_changeset())

      {:error, cs} =
        # Same owner + same name, different list_number.
        list_changeset(%{list_number: 2})
        |> Repo.insert()

      assert {"has already been taken", _} = cs.errors[:owner_id]
    end

    test "same name under different owners is allowed" do
      assert {:ok, _} = Repo.insert(list_changeset())

      seed_extra_user("CCCC11", "CCCC11A")

      cs =
        MailingList.changeset(%MailingList{}, %{
          owner_id: "CCCC11A",
          name: "FRIENDS",
          list_number: 1,
          max_members: 15
        })

      assert {:ok, _} = Repo.insert(cs)
    end
  end

  describe "MailingList changeset/2 - nickname/list-name collision is allowed" do
    # The DOS client SENDs the create-list request (subcode 0x0D0C)
    # without a matching RECEIVE, so a server-side rejection here
    # would trip OMCM 10 on the client.  Collision is intentionally
    # left to send-time resolution via
    # MessagingLists.resolve_recipients/2 (the "nickname wins" rule).
    # This test asserts the absence of a collision check; a future
    # regression that re-adds the validation will surface here.

    test "list name may match an existing address-book nickname for the same owner" do
      # The fixture seeds an abook entry with nickname "BRAVO".  A
      # list named "BRAVO" must still be insertable for the same
      # owner.
      cs = list_changeset(%{name: "BRAVO"})
      assert cs.valid?
      assert {:ok, %MailingList{name: "BRAVO"}} = Repo.insert(cs)
    end
  end

  # -- MailingListMember changesets -------------------------------

  defp seed_list_and_extra_entry do
    list =
      %MailingList{}
      |> MailingList.changeset(%{
        owner_id: "AAAA11A",
        name: "FRIENDS",
        list_number: 1,
        max_members: 15
      })
      |> Repo.insert!()

    seed_extra_user("CCCC11", "CCCC11A")

    extra_entry =
      %AddressBookEntry{}
      |> AddressBookEntry.changeset(%{
        owner_id: "AAAA11A",
        target_user_id: "CCCC11A",
        nickname: "CHARLIE",
        entry_number: 2
      })
      |> Repo.insert!()

    {list, extra_entry}
  end

  describe "MailingListMember changeset/2" do
    test "valid with both required FKs present", %{abook_entry: entry} do
      {list, _extra} = seed_list_and_extra_entry()

      cs =
        MailingListMember.changeset(%MailingListMember{}, %{
          mailing_list_id: list.id,
          address_book_entry_id: entry.id
        })

      assert cs.valid?
      assert {:ok, _} = Repo.insert(cs)
    end

    test "missing mailing_list_id is invalid", %{abook_entry: entry} do
      cs =
        MailingListMember.changeset(%MailingListMember{}, %{
          address_book_entry_id: entry.id
        })

      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:mailing_list_id]
    end

    test "missing address_book_entry_id is invalid" do
      {list, _extra} = seed_list_and_extra_entry()

      cs =
        MailingListMember.changeset(%MailingListMember{}, %{
          mailing_list_id: list.id
        })

      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:address_book_entry_id]
    end

    test "duplicate (mailing_list_id, address_book_entry_id) is rejected",
         %{abook_entry: entry} do
      {list, _extra} = seed_list_and_extra_entry()

      assert {:ok, _} =
               MailingListMember.changeset(%MailingListMember{}, %{
                 mailing_list_id: list.id,
                 address_book_entry_id: entry.id
               })
               |> Repo.insert()

      {:error, cs} =
        MailingListMember.changeset(%MailingListMember{}, %{
          mailing_list_id: list.id,
          address_book_entry_id: entry.id
        })
        |> Repo.insert()

      assert {"has already been taken", _} = cs.errors[:mailing_list_id]
    end
  end

  defp seed_extra_user(hh_id, user_id) do
    %Household{id: hh_id, enabled_date: @today}
    |> change
    |> put_assoc(:users, [
      %User{id: user_id, profile: %{}, date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()
  end
end
