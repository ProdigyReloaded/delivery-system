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

defmodule Prodigy.Portal.Layouts do
  use Prodigy.Portal, :html

  embed_templates "layouts/*"

  @doc """
  Short git revision this build came from, shown in the footer. Baked into the
  image via the GIT_SHA build arg (apps/server/Dockerfile); "dev" for source
  builds.
  """
  def revision do
    System.get_env("GIT_SHA", "dev") |> String.slice(0, 7)
  end
end
