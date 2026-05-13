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

defmodule Prodigy.Server.SessionManager do
  @moduledoc """
  Manages user sessions with concurrency control
  """

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.Session
  import Ecto.Query
  require Logger

  @pubsub Prodigy.Core.PubSub
  @topic "service:sessions"

  @doc "Topic admin LiveViews subscribe to for live session lifecycle events."
  def topic, do: @topic

  @logon_status %{
    success: 0,
    enroll_other: 1,
    enroll_subscriber: 2
  }

  @logoff_status %{
    normal: 0,
    abnormal: 1,
    timeout: 2,
    forced: 3,
    node_shutdown: 4
  }

  def create_session(user, status_atom, version \\ nil, opts \\ []) do
    with :ok <- check_concurrency(user),
         {:ok, session} <-
           %Session{}
           |> Session.changeset(%{
             user_id: user.id,
             logon_timestamp: DateTime.utc_now(),
             logon_status: @logon_status[status_atom],
             rs_version: version,
             node: Atom.to_string(node()),
             pid: pid_to_string(self()),
             last_activity_at: DateTime.utc_now(),
             transport: Keyword.get(opts, :transport),
             source_address: Keyword.get(opts, :source_address),
             source_port: Keyword.get(opts, :source_port)
           })
           |> Repo.insert() do
      broadcast({:session_opened, session.id})
      # Extra targeted broadcast the /start sidebar LiveView listens for so it
      # can auto-dismiss the fresh-password credentials card when the
      # portal user successfully signs on to the service. Existing
      # admin LiveViews key off :session_opened and ignore this one.
      broadcast({:service_user_authenticated, user.id})
      Prodigy.Core.ServiceEvents.broadcast_logon(session)
      {:ok, session}
    end
  end

  def close_session(user_id, status_atom) do
    # Find the active session for this user AND this pid
    session =
      from(s in Session,
        where: s.user_id == ^user_id,
        where: is_nil(s.logoff_timestamp),
        where: s.pid == ^pid_to_string(self()),
        limit: 1
      )
      |> Repo.one()

    if session do
      with {:ok, updated} <-
             session
             |> Session.changeset(%{
               logoff_timestamp: DateTime.utc_now(),
               logoff_status: @logoff_status[status_atom]
             })
             |> Repo.update() do
        broadcast({:session_closed, updated.id})
        Prodigy.Core.ServiceEvents.broadcast_logoff(updated)
        {:ok, updated}
      end
    else
      {:ok, nil}
    end
  end

  @doc """
  Call from places that mutate a service user's profile (name, title, etc.)
  so the admin LiveView can reload rows that display those fields. No-ops if
  the shared PubSub isn't running (tests, mix tasks).
  """
  def broadcast_profile_updated(user_id) when is_binary(user_id) do
    broadcast({:profile_updated, user_id})
  end

  defp broadcast(msg) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, msg)
  rescue
    # If the PubSub isn't running for some reason (tests, mix task), don't
    # crash the session write - the DB row is already committed.
    _ -> :ok
  end

  def user_logged_on?(user_id) do
    from(s in Session,
      where: s.user_id == ^user_id,
      where: is_nil(s.logoff_timestamp)
    )
    |> Repo.exists?()
  end

  def cleanup_node_sessions(node_name) do
    from(s in Session,
      where: s.node == ^node_name,
      where: is_nil(s.logoff_timestamp),
      update: [set: [
        logoff_timestamp: ^DateTime.utc_now(),
        logoff_status: ^@logoff_status[:node_shutdown]
      ]]
    )
    |> Repo.update_all([])
  end

  @doc """
  Close *every* open session row, regardless of which node they claim.
  Used on startup because the server's BEAM node name is derived from
  the container's random hostname, so it changes across rebuilds and
  `cleanup_node_sessions(node())` would never find its own prior rows.
  Safe under the current single-node Docker deploy; a multi-node setup
  would need stable node names + the node-scoped variant instead.
  """
  def cleanup_all_open_sessions do
    from(s in Session,
      where: is_nil(s.logoff_timestamp),
      update: [set: [
        logoff_timestamp: ^DateTime.utc_now(),
        logoff_status: ^@logoff_status[:node_shutdown]
      ]]
    )
    |> Repo.update_all([])
  end

  defp check_concurrency(user) do
    active_count =
      from(s in Session,
        where: s.user_id == ^user.id,
        where: is_nil(s.logoff_timestamp)
      )
      |> Repo.aggregate(:count)

    limit = user.concurrency_limit || 1

    cond do
      limit == 0 -> :ok
      active_count < limit -> :ok
      true -> {:error, :concurrency_exceeded}
    end
  end

  defp pid_to_string(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()
end
