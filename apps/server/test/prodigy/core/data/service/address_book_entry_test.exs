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

defmodule Prodigy.Core.Data.Service.AddressBookEntry.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase

  import Ecto.Changeset

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{AddressBookEntry, Household, User}

  @moduletag :capture_log

  @today DateTime.to_date(DateTime.utc_now())

  # Per-test fixture: an owner user (AAAA11A) and a separate target
  # user (BBBB11A) so we can exercise the address-book changeset
  # against both ends of the FK pair without polluting one with the
  # other.
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

    :ok
  end

  # Convenience for a valid baseline changeset.  Tests that exercise
  # a single failure mode start from this and override the offending
  # field, which keeps each test focused on the one thing it verifies.
  defp valid_attrs(overrides) do
    Map.merge(
      %{
        owner_id: "AAAA11A",
        target_user_id: "BBBB11A",
        nickname: "BRAVO",
        entry_number: 1
      },
      overrides
    )
  end

  defp changeset(overrides \\ %{}) do
    AddressBookEntry.changeset(%AddressBookEntry{}, valid_attrs(overrides))
  end

  describe "changeset/2 - required fields" do
    test "valid with all required fields present" do
      cs = changeset()
      assert cs.valid?
      assert {:ok, %AddressBookEntry{}} = Repo.insert(cs)
    end

    test "missing owner_id is invalid" do
      cs = changeset(%{owner_id: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:owner_id]
    end

    test "missing target_user_id is invalid" do
      cs = changeset(%{target_user_id: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:target_user_id]
    end

    test "missing nickname is invalid" do
      cs = changeset(%{nickname: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:nickname]
    end

    test "missing entry_number is invalid" do
      cs = changeset(%{entry_number: nil})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:entry_number]
    end
  end

  describe "changeset/2 - nickname format and length" do
    test "rejects nickname longer than 18 characters" do
      cs = changeset(%{nickname: String.duplicate("X", 19)})
      refute cs.valid?
      assert {_, [count: 18, validation: :length, kind: :max, type: :string]} =
               cs.errors[:nickname]
    end

    test "accepts nickname at the 18-character limit" do
      cs = changeset(%{nickname: String.duplicate("X", 18)})
      assert cs.valid?
    end

    # The DOS client refuses any nickname that looks like a Prodigy ID
    # (4 alpha + 2 digit + 1 hex alpha A-F).  We mirror that here so a
    # non-conforming client can't sneak one in over the wire.
    test "rejects nickname matching the Prodigy-ID format (uppercase)" do
      cs = changeset(%{nickname: "AAAA11A"})
      refute cs.valid?
      assert {"cannot look like a Prodigy ID", _} = cs.errors[:nickname]
    end

    test "rejects nickname matching the Prodigy-ID format (lowercase)" do
      cs = changeset(%{nickname: "aaaa11a"})
      refute cs.valid?
      assert {"cannot look like a Prodigy ID", _} = cs.errors[:nickname]
    end

    test "rejects nickname matching the Prodigy-ID format (mixed case)" do
      cs = changeset(%{nickname: "AaAa11a"})
      refute cs.valid?
      assert {"cannot look like a Prodigy ID", _} = cs.errors[:nickname]
    end

    test "accepts short nicknames that don't match the Prodigy-ID shape" do
      # 6 chars, alpha-only - shorter than the 7-char Prodigy ID
      cs = changeset(%{nickname: "FRIEND"})
      assert cs.valid?
    end

    test "accepts nickname with trailing letter outside A-F" do
      # last char is G - not in the hex-alpha range, so the regex
      # doesn't match
      cs = changeset(%{nickname: "AAAA11G"})
      assert cs.valid?
    end

    test "accepts nickname with non-digit middle chars" do
      cs = changeset(%{nickname: "AAAAABA"})
      assert cs.valid?
    end
  end

  describe "changeset/2 - entry_number range" do
    test "entry_number = 0 is invalid" do
      cs = changeset(%{entry_number: 0})
      refute cs.valid?
      assert {_, [validation: :number, kind: :greater_than, number: 0]} =
               cs.errors[:entry_number]
    end

    test "entry_number = 1 is valid (lower boundary)" do
      assert changeset(%{entry_number: 1}).valid?
    end

    test "entry_number = 50 is valid (upper boundary)" do
      assert changeset(%{entry_number: 50}).valid?
    end

    test "entry_number = 51 is invalid" do
      cs = changeset(%{entry_number: 51})
      refute cs.valid?

      assert {_, [validation: :number, kind: :less_than_or_equal_to, number: 50]} =
               cs.errors[:entry_number]
    end
  end

  describe "changeset/2 - unique constraints" do
    # The schema declares three unique constraints scoped to the
    # owner; each prevents a different kind of duplication.  These
    # tests verify the changeset-level error surface rather than
    # raising a constraint violation at the DB layer.

    test "duplicate (owner_id, entry_number) is rejected" do
      assert {:ok, _} = Repo.insert(changeset())

      {:error, cs} =
        changeset(%{nickname: "CHARLIE", target_user_id: "BBBB11A"})
        # same owner + same entry_number, different nickname
        |> Repo.insert()

      assert {"has already been taken", _} = cs.errors[:owner_id]
    end

    test "duplicate (owner_id, nickname) is rejected" do
      assert {:ok, _} = Repo.insert(changeset())

      # New entry_number, same nickname.  Need a second target so the
      # (owner_id, target_user_id) constraint isn't what fires first.
      seed_extra_user("CCCC11", "CCCC11A")

      {:error, cs} =
        changeset(%{entry_number: 2, target_user_id: "CCCC11A"})
        |> Repo.insert()

      assert {"has already been taken", _} = cs.errors[:owner_id]
    end

    test "duplicate (owner_id, target_user_id) is rejected" do
      # This is the path the user hit when trying to alias TEAM to the
      # same target as FOXTROT.  The intent is one nickname per target
      # per owner.
      assert {:ok, _} = Repo.insert(changeset())

      {:error, cs} =
        changeset(%{entry_number: 2, nickname: "TEAM"})
        |> Repo.insert()

      assert {"has already been taken", _} = cs.errors[:owner_id]
    end

    test "same nickname under different owners is allowed" do
      assert {:ok, _} = Repo.insert(changeset())

      # Second owner, same nickname text - should succeed.
      seed_extra_user("CCCC11", "CCCC11A")

      cs =
        AddressBookEntry.changeset(%AddressBookEntry{}, %{
          owner_id: "CCCC11A",
          target_user_id: "BBBB11A",
          nickname: "BRAVO",
          entry_number: 1
        })

      assert {:ok, _} = Repo.insert(cs)
    end
  end

  describe "changeset/2 - foreign-key constraints" do
    # foreign_key_constraint surfaces a constraint violation as a
    # changeset error rather than letting the underlying DB exception
    # escape.  Without it, an insert with a nonexistent target raises
    # Postgrex.Error, which is what produced the very first OMCM 10
    # in the bounce-investigation thread.

    test "nonexistent target_user_id returns a changeset error" do
      cs = changeset(%{target_user_id: "ZZZZ99A"})
      assert {:error, cs} = Repo.insert(cs)
      assert {_, _} = cs.errors[:target_user_id]
    end

    test "nonexistent owner_id returns a changeset error" do
      cs = changeset(%{owner_id: "ZZZZ99A"})
      assert {:error, cs} = Repo.insert(cs)
      assert {_, _} = cs.errors[:owner_id]
    end
  end

  # Helper used by the two tests that need a third user / household.
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
