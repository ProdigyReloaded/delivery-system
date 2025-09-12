defmodule Prodigy.Server.SessionCleanup do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  def terminate(_reason, _state) do
    Logger.info("SessionCleanup terminating, cleaning up all sessions...")

    try do
      # Force synchronous cleanup with a timeout
      Task.async(fn ->
        Prodigy.Server.SessionManager.cleanup_node_sessions(Atom.to_string(node()))
      end)
      |> Task.await(5000)

      Logger.info("Sessions cleaned up")
    rescue
      e ->
        Logger.error("Session cleanup failed: #{inspect(e)}")
    end

    :ok
  end
end