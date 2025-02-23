defmodule Prodigy.Server.Protocol.Tcs.Transmitter do
  use GenServer
  require Logger

  @back_pressure_size 4
  @run_interval 250

  # Public API

  def start_link(initial_state \\ %{}) do
    GenServer.start_link(__MODULE__, initial_state)
  end

  def send_code(pid, code, sequence) do
    GenServer.cast(pid, {code, sequence})
  end

  def transmit_packet(pid, packet, sequence) do
    GenServer.cast(pid, {:packet, packet, sequence})
  end


  # GenServer Callbacks

  @impl true
  def init(initial_state) do
    packet_queue = :queue.new()
    new_state = Map.merge(initial_state, %{packet_queue: packet_queue})
    {:ok, new_state, {:continue, :schedule_check_queue}}
  end

  @impl true
  def handle_cast({:packet, packet, sequence}, state) do
    Logger.debug("queuing packet with sequence: #{sequence}")
    new_queue = :queue.in({packet, sequence}, state.packet_queue)
    {:noreply, %{state | packet_queue: new_queue}, {:continue, :schedule_check_queue}}
  end

  @impl true
  def handle_cast({:ackpkt, sequence}, state) do
    Cachex.del(:transmit, {self(), sequence})
    Logger.debug("ackpkt received for sequence: #{sequence}")
    send(self(), :check_queue)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:nakcce, sequence}, state) do
    {:ok, packet_to_resend} = Cachex.get(:transmit, {self(), sequence})

    if packet_to_resend do
      Logger.debug("nakcce received for sequence: #{sequence}, resending")
      state.transport.send(state.socket, packet_to_resend)
    else
      Logger.warning("nakcce for sequence: #{sequence}, but no packet to resend")
    end

    send(self(), :check_queue)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:nakccc, sequence}, state) do
    # Might make it act the same as nakcce
    Logger.warning("nakccc received for sequence: #{sequence} - do nothing for now?")
    {:noreply, state}
  end

  @impl true
  def handle_continue(:schedule_check_queue, state) do
    Process.send_after(self(), :check_queue, @run_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_queue, state) do
    tx_self = self()
    {:ok, tx_keys} = Cachex.keys(:transmit)

    our_keys = Enum.filter(tx_keys, fn {pid, _} -> pid == tx_self end)
    new_state = if length(our_keys) > @back_pressure_size do
      state
    else
      case :queue.out(state.packet_queue) do
        {{:value, {packet, sequence}}, new_queue} ->
          Logger.debug("Sending packet with sequence: #{sequence}")
          state.transport.send(state.socket, packet)
          Cachex.put(:transmit, {tx_self, sequence}, packet)
          %{state | packet_queue: new_queue}
        {:empty, _packet_queue} ->
          state
      end
    end

    {:noreply, new_state, {:continue, :schedule_check_queue}}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.debug("#{inspect self()} Transmitter shutting down")
    :ok
  end
end
