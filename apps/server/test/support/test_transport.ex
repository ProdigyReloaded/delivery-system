# test/support/test_transport.ex
defmodule TestTransport do
  @moduledoc """
  Mock transport for testing TCS protocol
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{queue: :queue.new(), opts: %{}})
  end

  def send(pid, data) do
    GenServer.call(pid, {:send, data})
  end

  def setopts(pid, opts) do
    GenServer.call(pid, {:setopts, opts})
    :ok
  end

  def close(_pid) do
    :ok
  end

  def take(pid) do
    GenServer.call(pid, :take)
  end

  def count(pid) do
    GenServer.call(pid, :count)
  end

  # GenServer callbacks

  def init(state) do
    {:ok, state}
  end

  def handle_call({:send, data}, _from, state) do
    new_queue = :queue.in(data, state.queue)
    {:reply, :ok, %{state | queue: new_queue}}
  end

  def handle_call({:setopts, opts}, _from, state) do
    {:reply, :ok, %{state | opts: opts}}
  end

  def handle_call(:take, _from, state) do
    case :queue.out(state.queue) do
      {{:value, item}, new_queue} ->
        {:reply, item, %{state | queue: new_queue}}
      {:empty, _} ->
        {:reply, nil, state}
    end
  end

  def handle_call(:count, _from, state) do
    {:reply, :queue.len(state.queue), state}
  end
end