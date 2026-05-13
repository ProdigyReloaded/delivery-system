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

defmodule Prodigy.Portal.Admin.UsersTest do
  use Prodigy.Portal.DataCase, async: true

  alias Prodigy.Core.Data.Service.{Enroller, Household, User}
  alias Prodigy.Portal.Admin.Users

  defp subscriber!(id \\ "AAAA11") do
    {:ok, {household, user}} =
      Enroller.create_subscriber(id, "SECRET",
        concurrency_limit: 1,
        enroll_name: {"Alice", "Smith"}
      )

    {household, user}
  end

  describe "edit_changeset/2" do
    test "casts name/title/gender/birthdate/concurrency_limit" do
      {_hh, user} = subscriber!()

      cs =
        Users.edit_changeset(user, %{
          "first_name" => "Alicia",
          "gender" => "F",
          "birthdate" => "1985-03-14",
          "concurrency_limit" => "2"
        })

      assert cs.valid?
      assert get_change(cs, :first_name) == "Alicia"
      assert get_change(cs, :gender) == "F"
      assert get_change(cs, :birthdate) == ~D[1985-03-14]
      assert get_change(cs, :concurrency_limit) == 2
    end

    test "ignores fields outside the admin allow-list" do
      {_hh, user} = subscriber!()

      cs =
        Users.edit_changeset(user, %{
          "first_name" => "Alicia",
          "password" => "HACKED",
          "date_enrolled" => "1999-01-01",
          "date_deleted" => "1999-01-01"
        })

      # UserForm doesn't know those fields - not present in cast output.
      refute Map.has_key?(cs.changes, :password)
      refute Map.has_key?(cs.changes, :date_enrolled)
      refute Map.has_key?(cs.changes, :date_deleted)
    end

    test "read-only status formatters display enrollment + last-logon state" do
      alias Prodigy.Core.Data.Service.User
      alias Prodigy.Portal.Admin.UserForm

      assert UserForm.format_enrolled(%User{date_enrolled: nil}) =~ "No"
      assert UserForm.format_enrolled(%User{date_enrolled: ~D[2026-04-18]}) =~ "2026-04-18"

      assert UserForm.format_last_logon(%User{profile: %{}}) == "Never"

      assert UserForm.format_last_logon(%User{
               profile: %{"02C2" => "04/18/2026", "02C4" => "14.30"}
             }) == "04/18/2026 14.30"
    end

    test "seeds form values from JSONB so the modal renders correctly" do
      # Enroller writes name/title/gender into JSONB. The form view
      # model must surface those back to the caller so the first
      # render shows them.
      {_hh, user} = subscriber!()

      cs = Users.edit_changeset(user)
      data = cs.data

      assert data.first_name == "Alice"
      assert data.last_name == "Smith"
      assert data.title == "Mr."
      assert data.gender == "M"
      assert data.concurrency_limit == 1
    end

    test "rejects negative concurrency_limit" do
      {_hh, user} = subscriber!()
      cs = Users.edit_changeset(user, %{"concurrency_limit" => -1})
      refute cs.valid?
      assert %{concurrency_limit: [_ | _]} = errors_on(cs)
    end
  end

  describe "update/2" do
    test "writes gender + birthdate to the user's JSONB profile" do
      {_hh, user} = subscriber!()

      {:ok, updated} =
        Users.update(user, %{
          "first_name" => "Alice",
          "last_name" => "Smith",
          "gender" => "F",
          "birthdate" => "1985-03-14"
        })

      reloaded = Repo.get(User, updated.id)

      # 0x0157 = gender, 0x0162 = birthdate (MMDDYY)
      assert reloaded.profile["0157"] == "F"
      assert reloaded.profile["0162"] == "031485"
    end

    test "mirrors name/title into the household's slot JSONB" do
      {_hh, user} = subscriber!()

      {:ok, updated} =
        Users.update(user, %{
          "first_name" => "Alicia",
          "middle_name" => "Q",
          "last_name" => "Smythe",
          "title" => "Dr.",
          "concurrency_limit" => "1"
        })

      hh = Repo.get(Household, updated.household_id)
      keys = Household.slot_keys("a")

      assert hh.profile[keys.first] == "Alicia"
      assert hh.profile[keys.middle] == "Q"
      assert hh.profile[keys.last] == "Smythe"
      assert hh.profile[keys.title] == "Dr."
    end

    test "names land in JSONB only (no legacy columns on the schema)" do
      {_hh, user} = subscriber!()

      {:ok, updated} =
        Users.update(user, %{
          "first_name" => "Alicia",
          "last_name" => "Smythe",
          "concurrency_limit" => "1"
        })

      reloaded = Repo.get(User, updated.id)
      assert reloaded.profile["015F"] == "Alicia"
      assert reloaded.profile["015E"] == "Smythe"
      # Schema no longer carries legacy name fields.
      refute Map.has_key?(reloaded, :first_name)
      refute Map.has_key?(reloaded, :last_name)
    end

    test "writes personal path jumpwords to their TAC keys in JSONB" do
      {_hh, user} = subscriber!()

      {:ok, updated} =
        Users.update(user, %{
          "path_1" => "NEWS",
          "path_2" => "WEATHER",
          # path 13 is 0x020A, not contiguous with path_1..12 (0x023F..)
          "path_13" => "TRAVEL",
          "concurrency_limit" => "1"
        })

      reloaded = Repo.get(User, updated.id)
      assert reloaded.profile["023F"] == "NEWS"
      assert reloaded.profile["0240"] == "WEATHER"
      assert reloaded.profile["020A"] == "TRAVEL"
    end

    test "clearing a previously-set jumpword removes its JSONB key" do
      {_hh, user} = subscriber!()

      {:ok, _} =
        Users.update(user, %{"path_1" => "NEWS", "concurrency_limit" => "1"})

      reloaded = Repo.get(User, user.id)
      assert reloaded.profile["023F"] == "NEWS"

      {:ok, _} =
        Users.update(reloaded, %{"path_1" => "", "concurrency_limit" => "1"})

      reloaded = Repo.get(User, user.id)
      refute Map.has_key?(reloaded.profile, "023F")
    end

    test "rejects a jumpword longer than 13 chars (ProfileSchema max)" do
      {_hh, user} = subscriber!()

      cs =
        Users.edit_changeset(user, %{
          "path_1" => "THIS_IS_WAY_TOO_LONG_FOR_A_PATH",
          "concurrency_limit" => "1"
        })

      refute cs.valid?
      assert %{path_1: [_ | _]} = errors_on(cs)
    end

    test "writes address/phone changes to the household's JSONB, not the user's" do
      {_hh, user} = subscriber!()

      {:ok, updated} =
        Users.update(user, %{
          "address_1" => "123 Main St",
          "city" => "Brooklyn",
          "zipcode" => "11201",
          "telephone" => "5551234567",
          "concurrency_limit" => "1"
        })

      reloaded_user = Repo.get(User, updated.id)
      reloaded_hh = Repo.get(Household, updated.household_id)

      # Household TACs land on the household.
      assert reloaded_hh.profile["0102"] == "123 Main St"
      assert reloaded_hh.profile["0104"] == "Brooklyn"
      assert reloaded_hh.profile["0106"] == "11201"
      assert reloaded_hh.profile["0107"] == "5551234567"
      # User profile untouched by household-only edit.
      refute Map.has_key?(reloaded_user.profile, "0102")
    end

    test "admin edit preserves JSONB keys written by a prior TCS-only path" do
      # TCS writes go to JSONB. When an admin later edits gender,
      # the JSONB keys written by TCS (here: last_name) must survive.
      {_hh, user} = subscriber!()

      {:ok, user} =
        user
        |> Ecto.Changeset.change(%{
          profile: Map.put(user.profile || %{}, "015E", "Carmichael")
        })
        |> Repo.update()

      assert user.profile["015E"] == "Carmichael"

      {:ok, updated} =
        Users.update(user, %{"gender" => "F", "concurrency_limit" => "1"})

      reloaded = Repo.get(User, updated.id)
      assert reloaded.profile["015E"] == "Carmichael"
      assert reloaded.profile["0157"] == "F"
    end
  end
end
