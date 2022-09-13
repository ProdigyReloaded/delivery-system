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

defmodule WaitFor do
  # returns the number of milliseconds since January 1, 1970
  defp epoch_ms(), do: DateTime.utc_now() |> DateTime.to_unix(:millisecond)

  @doc """
  Wait for the `condition` process to return true.
  """
  def wait_for(condition, {:deadline, deadline} = opts) do
    if epoch_ms() >= deadline do
      :timeout
    else
      if condition.() do
        :ok
      else
        Process.sleep(100)
        wait_for(condition, opts)
      end
    end
  end

  def wait_for(condition, timeout) do
    wait_for(condition, {:deadline, epoch_ms() + timeout})
  end
end

ExUnit.start(exclude: [:skip])
