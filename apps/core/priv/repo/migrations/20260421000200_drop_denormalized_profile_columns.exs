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

defmodule Prodigy.Core.Data.Repo.Migrations.DropDenormalizedProfileColumns do
  use Ecto.Migration

  @moduledoc """
  Drop every denormalized profile column from `user` and `household`.
  JSONB `profile` is the sole store for these values as of this
  migration.

  Housekeeping columns (password, concurrency_limit, date_enrolled,
  date_deleted, enabled/disabled_date, disabled_reason, the FK columns)
  are deliberately kept - they're queried structurally and aren't
  TAC-addressable profile data.

  Irreversible: the `down/0` block re-adds empty columns but the
  original data is in JSONB and not copied back. A pg_dump prior to
  running the forward migration is the supported rollback path.
  """

  def up do
    alter table(:user) do
      remove(:gender)
      remove(:first_name)
      remove(:middle_name)
      remove(:last_name)
      remove(:title)
      remove(:birthdate)
      remove(:prf_path_jumpword_1)
      remove(:prf_path_jumpword_2)
      remove(:prf_path_jumpword_3)
      remove(:prf_path_jumpword_4)
      remove(:prf_path_jumpword_5)
      remove(:prf_path_jumpword_6)
      remove(:prf_path_jumpword_7)
      remove(:prf_path_jumpword_8)
      remove(:prf_path_jumpword_9)
      remove(:prf_path_jumpword_10)
      remove(:prf_path_jumpword_11)
      remove(:prf_path_jumpword_12)
      remove(:prf_path_jumpword_13)
      remove(:prf_path_jumpword_14)
      remove(:prf_path_jumpword_15)
      remove(:prf_path_jumpword_16)
      remove(:prf_path_jumpword_17)
      remove(:prf_path_jumpword_18)
      remove(:prf_path_jumpword_19)
      remove(:prf_path_jumpword_20)
      remove(:prf_last_logon_date)
      remove(:prf_last_logon_time)
      remove(:prf_madmaze_save)
    end

    alter table(:household) do
      remove(:address_1)
      remove(:address_2)
      remove(:city)
      remove(:state)
      remove(:zipcode)
      remove(:telephone)
      remove(:subscriber_suffix)
      remove(:household_password)

      for slot <- ~w(a b c d e f) do
        remove(String.to_atom("user_#{slot}_last"))
        remove(String.to_atom("user_#{slot}_first"))
        remove(String.to_atom("user_#{slot}_middle"))
        remove(String.to_atom("user_#{slot}_title"))
        remove(String.to_atom("user_#{slot}_access_level"))
        remove(String.to_atom("user_#{slot}_indicators"))
      end
    end
  end

  def down do
    alter table(:user) do
      add(:gender, :string)
      add(:first_name, :string)
      add(:middle_name, :string)
      add(:last_name, :string)
      add(:title, :string)
      add(:birthdate, :date)

      for n <- 1..20 do
        add(String.to_atom("prf_path_jumpword_#{n}"), :binary)
      end

      add(:prf_last_logon_date, :string)
      add(:prf_last_logon_time, :string)
      add(:prf_madmaze_save, :binary)
    end

    alter table(:household) do
      add(:address_1, :string)
      add(:address_2, :string)
      add(:city, :string)
      add(:state, :string)
      add(:zipcode, :string)
      add(:telephone, :string)
      add(:subscriber_suffix, :string)
      add(:household_password, :string)

      for slot <- ~w(a b c d e f) do
        add(String.to_atom("user_#{slot}_last"), :string)
        add(String.to_atom("user_#{slot}_first"), :string)
        add(String.to_atom("user_#{slot}_middle"), :string)
        add(String.to_atom("user_#{slot}_title"), :string)
        add(String.to_atom("user_#{slot}_access_level"), :string)
        add(String.to_atom("user_#{slot}_indicators"), :string)
      end
    end
  end
end
