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

defmodule Prodigy.Portal.DataCase do
  @moduledoc """
  Foundation for tests that need access to the database via the shared
  `Prodigy.Core.Data.Repo` in an Ecto SQL sandbox. Async tests each get
  their own ownership; non-async tests share the sandbox (set `:async`
  on the test module as appropriate).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Prodigy.Core.Data.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Prodigy.Portal.DataCase
    end
  end

  setup tags do
    Prodigy.Portal.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Starts a sandbox owner for the given test tags."
  def setup_sandbox(tags) do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(
        Prodigy.Core.Data.Repo,
        shared: not tags[:async]
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Converts a changeset's errors into a map of `%{field => [messages]}` so tests
  can assert on human-readable validation output.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
