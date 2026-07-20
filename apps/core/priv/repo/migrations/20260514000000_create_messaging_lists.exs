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

defmodule Prodigy.Core.Data.Repo.Migrations.CreateMessagingLists do
  use Ecto.Migration

  def change do
    create table(:address_book_entries) do
      add :owner_id, references(:user, type: :string, on_delete: :delete_all), null: false
      add :target_user_id, references(:user, type: :string, on_delete: :restrict), null: false
      add :nickname, :string, null: false
      add :entry_number, :integer, null: false

      timestamps()
    end

    create unique_index(:address_book_entries, [:owner_id, :entry_number])
    create unique_index(:address_book_entries, [:owner_id, :nickname])
    create unique_index(:address_book_entries, [:owner_id, :target_user_id])
    create index(:address_book_entries, [:owner_id])

    create table(:mailing_lists) do
      add :owner_id, references(:user, type: :string, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :list_number, :integer, null: false
      add :max_members, :integer, default: 10

      timestamps()
    end

    create unique_index(:mailing_lists, [:owner_id, :list_number])
    create unique_index(:mailing_lists, [:owner_id, :name])
    create index(:mailing_lists, [:owner_id])

    create table(:mailing_list_members, primary_key: false) do
      add :mailing_list_id, references(:mailing_lists, on_delete: :delete_all), null: false
      add :address_book_entry_id, references(:address_book_entries, on_delete: :delete_all), null: false
      add :position, :integer

      timestamps()
    end

    create unique_index(:mailing_list_members, [:mailing_list_id, :address_book_entry_id])
    create index(:mailing_list_members, [:mailing_list_id])
    create index(:mailing_list_members, [:address_book_entry_id])
  end
end
