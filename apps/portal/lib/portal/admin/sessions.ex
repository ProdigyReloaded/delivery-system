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

defmodule Prodigy.Portal.Admin.Sessions do
  @moduledoc """
  Queries and actions the admin "Who's online" tab calls into. Keeps
  query shapes + pid/node resolution out of the LiveView so the LiveView can
  stay about rendering + event handling.
  """
  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Session, User}

  require Logger

  @doc """
  All active TCS sessions (logoff_timestamp IS NULL) with their user +
  household + optional portal_user preloaded. Newest sessions first.
  """
  def list_online do
    from(s in Session,
      where: is_nil(s.logoff_timestamp),
      join: u in User,
      on: u.id == s.user_id,
      preload: [user: {u, [:household, :portal_user]}],
      order_by: [desc: s.logon_timestamp]
    )
    |> Repo.all()
  end

  @doc """
  Terminates the TCS GenServer backing `session`. Resolves the stored
  pid_string + node, and if the process is local and alive, signals
  `:shutdown` so the GenServer's handle_info({:EXIT, ...}) path tears
  down the connection cleanly and the session row picks up a logoff
  timestamp + `:forced` status from the SessionManager callback.

  Returns `:ok | {:error, :stale} | {:error, {:remote_node, node}}`.
  Stale means pid_to_list parsed fine but the process is gone (in that
  case we also mark the row as force-logged-off so the online list
  refreshes clean). Remote-node support isn't wired yet - if the
  session lives on a node other than our own, we refuse rather than
  guess what the caller wanted; a multi-node deploy needs explicit RPC.
  """
  def disconnect(%Session{pid: nil}), do: {:error, :no_pid_recorded}

  def disconnect(%Session{pid: pid_str, node: node_str} = session) do
    target_node = String.to_atom(node_str)

    cond do
      target_node != node() ->
        {:error, {:remote_node, target_node}}

      true ->
        pid = safe_pid_from_string(pid_str)

        cond do
          is_nil(pid) ->
            mark_forced_logoff(session)
            {:error, :stale}

          not Process.alive?(pid) ->
            mark_forced_logoff(session)
            {:error, :stale}

          true ->
            Logger.info(
              "admin disconnect: signaling Router #{inspect(pid)} for session #{session.id}"
            )

            Process.exit(pid, :shutdown)
            :ok
        end
    end
  end

  # pid_to_list produces `~c"<0.123.0>"`. The inverse list_to_pid raises on
  # malformed input; wrap defensively.
  defp safe_pid_from_string(str) when is_binary(str) do
    str |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    _ -> nil
  end

  defp safe_pid_from_string(_), do: nil

  defp mark_forced_logoff(%Session{} = session) do
    # session.logoff_timestamp is :utc_datetime (second precision); the
    # default DateTime.utc_now() carries microseconds and Ecto rejects
    # that shape. Truncate before handing off.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    session
    |> Ecto.Changeset.change(
      logoff_timestamp: now,
      logoff_status: 3
    )
    |> Repo.update()
  end
end
