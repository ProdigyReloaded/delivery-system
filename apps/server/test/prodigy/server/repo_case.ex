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

defmodule Prodigy.Server.RepoCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Prodigy.Core.Data.Repo

      import Ecto
      import Ecto.Query
      import Prodigy.Server.RepoCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Prodigy.Core.Data.Repo, shared: not tags[:async])
    on_exit(fn ->
      # we need to delay shutdown long enough for the router to clean up so we can avoid log messages that
      # look like errors.  These errors arise because we finish our assertions and the test concludes, but when
      # the Router process terminates, it calls it's hooks which handle what appear to be abnormal user
      # disconnections.  They try and write to the database that has already shutdown.

      # A possibly better alternative would be an on_exit hook in the test setup where the Router's termination
      # is awaited.  Doesn't seem there is an on_exit callback for setup_with_mocks, though.

      Process.sleep(10)
      Sandbox.stop_owner(pid)
    end)

    :ok
  end
end
