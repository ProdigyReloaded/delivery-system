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

defmodule Prodigy.Core.Data.User do
  use Ecto.Schema

  @moduledoc """
  Schema specific to individual users and related change functions
  """

  @primary_key {:id, :string, []}
  schema "user" do
    belongs_to(:household, Prodigy.Core.Data.Household, type: :string)
    has_one(:data_collection_policy, Prodigy.Core.Data.DataCollectionPolicy)
    field(:password, Comeonin.Ecto.Password)
    field(:gender, :string)
    field(:date_enrolled, :date)
    field(:date_deleted, :date)
    field(:logged_on, :boolean)
    field(:last_name, :string)
    field(:first_name, :string)
    field(:middle_name, :string)
    field(:title, :string)
    field(:birthdate, :date)

    field(:prf_path_jumpword_1, :binary)
    field(:prf_path_jumpword_2, :binary)
    field(:prf_path_jumpword_3, :binary)
    field(:prf_path_jumpword_4, :binary)
    field(:prf_path_jumpword_5, :binary)
    field(:prf_path_jumpword_6, :binary)
    field(:prf_path_jumpword_7, :binary)
    field(:prf_path_jumpword_8, :binary)
    field(:prf_path_jumpword_9, :binary)
    field(:prf_path_jumpword_10, :binary)
    field(:prf_path_jumpword_11, :binary)
    field(:prf_path_jumpword_12, :binary)
    field(:prf_path_jumpword_13, :binary)
    field(:prf_path_jumpword_14, :binary)
    field(:prf_path_jumpword_15, :binary)
    field(:prf_path_jumpword_16, :binary)
    field(:prf_path_jumpword_17, :binary)
    field(:prf_path_jumpword_18, :binary)
    field(:prf_path_jumpword_19, :binary)
    field(:prf_path_jumpword_20, :binary)

    field(:prf_last_logon_date, :string)
    field(:prf_last_logon_time, :string)

    field(:prf_madmaze_save, :binary)
  end

  def changeset(user, params \\ %{}) do
    user
    # TODO there must be a better way that isn't just calling change
    |> Ecto.Changeset.cast(params, [
      :password,
      :gender,
      :last_name,
      :first_name,
      :middle_name,
      :title,
      :birthdate,
      :prf_path_jumpword_1,
      :prf_path_jumpword_2,
      :prf_path_jumpword_3,
      :prf_path_jumpword_4,
      :prf_path_jumpword_5,
      :prf_path_jumpword_6,
      :prf_path_jumpword_7,
      :prf_path_jumpword_8,
      :prf_path_jumpword_9,
      :prf_path_jumpword_10,
      :prf_path_jumpword_11,
      :prf_path_jumpword_12,
      :prf_path_jumpword_13,
      :prf_path_jumpword_14,
      :prf_path_jumpword_15,
      :prf_path_jumpword_16,
      :prf_path_jumpword_17,
      :prf_path_jumpword_18,
      :prf_path_jumpword_19,
      :prf_path_jumpword_20
    ])
  end
end
