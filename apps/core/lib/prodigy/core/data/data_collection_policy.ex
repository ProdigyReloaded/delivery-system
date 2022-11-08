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

defmodule Prodigy.Core.Data.DataCollectionPolicy do
  use Ecto.Schema

  @moduledoc """
  Schema specific to user-specific Data Collection elements
  """

  @primary_key false
  schema "data_collection_policy" do
    field(:user_id, :string, primary_key: true)
    field(:template, :boolean)
    field(:element, :boolean)
    field(:ad, :boolean)
    field(:pwindow, :boolean)
    field(:commit, :boolean)
    field(:next, :boolean)
    field(:back, :boolean)
    field(:jump, :boolean)
    field(:help, :boolean)
    field(:path, :boolean)
    field(:undo, :boolean)
    field(:exit, :boolean)
    field(:look, :boolean)
    field(:action, :boolean)
  end
end
