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

  # Somtimes DS gets both a nakcce and nakccc so we mark when we send a packet with a nakcce
  @impl true
  def handle_cast({:nakcce, sequence}, state) do
    {:ok, value} = Cachex.get(:transmit, {self(), sequence})

    Logger.debug("nakcce received for sequence: #{sequence}, outside if")
    if value do
      {_cce_sent, packet_to_resend} = value
      Logger.debug("nakcce received for sequence: #{sequence}, resending")
      state.transport.send(state.socket, packet_to_resend)
      # update the cce_sent status so it won't be sent with a nakccc
      Cachex.put(:transmit, {self(), sequence}, {true, packet_to_resend})
    else
      Logger.warning("nakcce for sequence: #{sequence}, but no packet to resend")
    end

    send(self(), :check_queue)
    {:noreply, state}
  end

  # Sometimes DS gets both a nakcce and nakccc so we only send if we haven't sent a nakcce
  @impl true
  def handle_cast({:nakccc, sequence}, state) do
    {:ok, value} = Cachex.get(:transmit, {self(), sequence})
    Logger.debug("nakccc received for sequence: #{sequence}, outside if")

    if value do
      {cce_sent, packet_to_resend} = value
      if (cce_sent) do
        Logger.debug("nakccc received for sequence: #{sequence}, but nakcce was sent")
      else
        Logger.debug("nakccc received for sequence: #{sequence}, resending")
        state.transport.send(state.socket, packet_to_resend)
      end
    else
      Logger.warning("nakccc for sequence: #{sequence}, but no packet to resend")
    end

    send(self(), :check_queue)
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
          # store the packet in the cache so we can resend it if we get a nakcce or nakccc
          # cce_sent is false because we haven't sent a nakcce yet
          Cachex.put(:transmit, {tx_self, sequence}, {false, packet})
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
