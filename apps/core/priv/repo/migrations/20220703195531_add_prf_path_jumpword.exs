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

defmodule Prodigy.Core.Data.Repo.Migrations.AddPrfPathJumpword do
  use Ecto.Migration

  # TODO viewpath works in 6.03.17, but not in 6.03.10; maybe backport the object
  #   from 6.03.17 that makes it work?

  def change do
    alter table(:user) do
      add :prf_path_jumpword_1, :string
      add :prf_path_jumpword_2, :string
      add :prf_path_jumpword_3, :string
      add :prf_path_jumpword_4, :string
      add :prf_path_jumpword_5, :string
      add :prf_path_jumpword_6, :string
      add :prf_path_jumpword_7, :string
      add :prf_path_jumpword_8, :string
      add :prf_path_jumpword_9, :string
      add :prf_path_jumpword_10, :string
      add :prf_path_jumpword_11, :string
      add :prf_path_jumpword_12, :string
      add :prf_path_jumpword_13, :string
      add :prf_path_jumpword_14, :string
      add :prf_path_jumpword_15, :string
      add :prf_path_jumpword_16, :string
      add :prf_path_jumpword_17, :string
      add :prf_path_jumpword_18, :string
      add :prf_path_jumpword_19, :string
      add :prf_path_jumpword_20, :string
    end
  end
end
