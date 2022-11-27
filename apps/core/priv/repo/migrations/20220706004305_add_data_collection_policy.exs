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

defmodule Prodigy.Core.Data.Repo.Migrations.AddDataCollectionPolicy do
  use Ecto.Migration

  def change do
    create table(:data_collection_policy, primary_key: false) do
      add :user_id, :string, primary_key: true
      add :template, :boolean
      add :element, :boolean
      add :ad, :boolean
      add :pwindow, :boolean
      add :commit, :boolean
      add :next, :boolean
      add :back, :boolean
      add :jump, :boolean
      add :help, :boolean
      add :path, :boolean
      add :undo, :boolean
      add :exit, :boolean
      add :look, :boolean
      add :action, :boolean
    end

    alter table(:user) do
      add :data_collection_policy_id, references(:data_collection_policy, column: :user_id, type: :string)
    end
  end
end
