defmodule Prodigy.Server.SessionManager do
  @moduledoc """
  Manages user sessions with concurrency control
  """

  alias Prodigy.Core.Data.{Session, User, Repo}
  import Ecto.Query
  require Logger

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

  def create_session(user, status_atom, version \\ nil) do
    with :ok <- check_concurrency(user) do
      %Session{}
      |> Session.changeset(%{
        user_id: user.id,
        logon_timestamp: DateTime.utc_now(),
        logon_status: @logon_status[status_atom],
        rs_version: version,
        node: Atom.to_string(node()),
        pid: pid_to_string(self()),
        last_activity_at: DateTime.utc_now()
      })
      |> Repo.insert()
    end
  end

  def close_session(user_id, status_atom) do
    session =
      from(s in Session,
        where: s.user_id == ^user_id,
        where: is_nil(s.logoff_timestamp),
        where: s.pid == ^pid_to_string(self()),
        limit: 1
      )
      |> Repo.one()

    if session do
      session
      |> Session.changeset(%{
        logoff_timestamp: DateTime.utc_now(),
        logoff_status: @logoff_status[status_atom]
      })
      |> Repo.update()
    else
      {:ok, nil}
    end
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

  def cleanup_stale_sessions(timeout_minutes \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-timeout_minutes * 60)

    from(s in Session,
      where: is_nil(s.logoff_timestamp),
      where: s.last_activity_at < ^cutoff,
      update: [set: [
        logoff_timestamp: ^DateTime.utc_now(),
        logoff_status: ^@logoff_status[:timeout]
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
