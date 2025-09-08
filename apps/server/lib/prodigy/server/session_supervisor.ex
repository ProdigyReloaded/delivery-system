defmodule Prodigy.Server.SessionSupervisor do
  use GenServer
  alias Prodigy.Server.SessionManager
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    # Clean up orphaned sessions from this node
    SessionManager.cleanup_node_sessions(Atom.to_string(node()))

    # Schedule periodic cleanup
    schedule_cleanup()

    # Trap exits to cleanup on shutdown
    Process.flag(:trap_exit, true)

    {:ok, %{}}
  end

  def handle_info(:cleanup_stale, state) do
    SessionManager.cleanup_stale_sessions()
    schedule_cleanup()
    {:noreply, state}
  end

  def terminate(_reason, _state) do
    Logger.info("SessionSupervisor shutting down, cleaning up sessions...")
    SessionManager.cleanup_node_sessions(Atom.to_string(node()))
    :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_stale, :timer.minutes(5))
  end
end