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
  defp epoch_ms, do: DateTime.utc_now() |> DateTime.to_unix(:millisecond)

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

defmodule Server do
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router
  alias Prodigy.Core.Data.{Repo, User}

  import Ecto.Query

  def logon(pid, user, pass, version) do
    Router.handle_packet(pid, %Fm0{
      src: 0x0,
      dest: 0x2200,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: <<0x1, user::binary, String.length(pass), pass::binary, version::binary>>
    })
  end

  def logoff(pid) do
    Router.handle_packet(pid, %Fm0{
      src: 0x0,
      dest: 0xD201,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0
    })
  end

  def logged_on?(user_id) do
    User
    |> where([u], u.id == ^user_id)
    |> first()
    |> Repo.one()
    |> Map.get(:logged_on)
  end
end

ExUnit.start(exclude: [:skip])
