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

defmodule Prodigy.Core.Data.Repo do
  @moduledoc """
  The Ecto-backed Database repository
  """

  use Ecto.Repo,
    otp_app: :core,
    adapter: Application.compile_env!(:core, :ecto_adapter)

  import Ecto.Query, only: [from: 2]

  @doc """
  Convenience wrapper used by Phoenix 1.7 phx.gen.auth-generated code:
  `Repo.all_by(Schema, key: value)` returns all rows matching the clauses.
  """
  def all_by(queryable, clauses) when is_list(clauses) do
    all(from q in queryable, where: ^clauses)
  end

  @doc """
  Convenience wrapper used by Phoenix 1.7 phx.gen.auth-generated code:
  equivalent to `transaction/1` but returning `{:ok, result} | {:error, reason}`
  for plain anonymous functions.
  """
  def transact(fun, opts \\ []) when is_function(fun, 0) do
    transaction(
      fn ->
        case fun.() do
          {:ok, value} -> value
          :ok -> :transact_ok
          {:error, reason} -> rollback(reason)
          :error -> rollback(:error)
          other -> other
        end
      end,
      opts
    )
    |> case do
      {:ok, :transact_ok} -> :ok
      result -> result
    end
  end
end
