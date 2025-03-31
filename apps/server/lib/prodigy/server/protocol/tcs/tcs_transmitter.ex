defmodule Prodigy.Server.Protocol.Tcs.Transmitter do
  use GenServer
  require Logger

  alias Prodigy.Server.Protocol.Tcs.Packet

  @back_pressure_size 6
  @rs_buffer_size 8
  @wack_threshold 4
  # in seconds
  @wack_interval 10
  @run_interval 250

  defmodule PacketState do
    @moduledoc "A structure containing the state utilized through the lifecycle of a TCS connection"
    defstruct [
      :nakcce_received,
      :wack_count,
      :sent_time,
      :packet,
      :transmitted,
      :acked
    ]
  end

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
    {:ok, new_state, {:continue, :schedule_run_checks}}
  end

  @impl true
  def handle_cast({:packet, packet, sequence}, state) do
    Logger.debug("queuing packet with sequence: #{sequence}")
    new_queue = :queue.in({packet, sequence}, state.packet_queue)
    {:noreply, %{state | packet_queue: new_queue}, {:continue, :schedule_run_checks}}
  end

  @impl true
  def handle_cast({:ackpkt, sequence}, state) do
    ## XXX Add list check
    Cachex.del(:transmit, {self(), sequence})
    Logger.debug("ackpkt received for sequence: #{sequence}")
    send(self(), :run_checks)
    {:noreply, state}
  end

  # Somtimes DS gets both a nakcce and nakncc so we mark when we send a packet with a nakcce
  @impl true
  def handle_cast({:nakcce, sequence}, state) do
    {:ok, packet_state} = Cachex.get(:transmit, {self(), sequence})

    Logger.debug("nakcce received for sequence: #{sequence}, outside if")

    if packet_state do
      %PacketState{packet: packet} = packet_state
      Logger.debug("nakcce received for sequence: #{sequence}, resending")
      state.transport.send(state.socket, packet)
      # update the nakcce_received status so it won't be sent with a nakncc
      Cachex.put(:transmit, {self(), sequence}, %PacketState{packet_state | nakcce_received: true})
    else
      Logger.warning("nakcce for sequence: #{sequence}, but no packet to resend")
    end

    send(self(), :run_checks)
    {:noreply, state}
  end

  # Sometimes DS gets both a nakcce and nakncc so we only send if we haven't sent a nakcce
  @impl true
  def handle_cast({:nakncc, sequence}, state) do
    {:ok, packet_state} = Cachex.get(:transmit, {self(), sequence})
    Logger.debug("nakncc received for sequence: #{sequence}, outside if")

    if packet_state do
      %PacketState{nakcce_received: nakcce_received, packet: packet} = packet_state

      if nakcce_received do
        Logger.debug("nakncc received for sequence: #{sequence}, but nakcce was already received")
      else
        Logger.debug("nakncc received for sequence: #{sequence}, resending")
        state.transport.send(state.socket, packet)
      end
    else
      Logger.warning("nakncc for sequence: #{sequence}, but no packet to resend")
    end

    send(self(), :run_checks)
    {:noreply, state}
  end

  @impl true
  def handle_continue(:schedule_run_checks, state) do
    Process.send_after(self(), :run_checks, @run_interval)
    {:noreply, state}
  end

  @doc """
  This function has two main responsibilities:
  1. Check to see if a packet has a wackpk that needs to be sent. If the current time is more
      than @wack_interval seconds after the last time we sent a wackpk, then we send one, then
      save the incremented wack_count and the current time.
  2. Check to see if we can send a packet from the queue
  """
  @impl true
  def handle_info(:run_checks, state) do
    tx_self = self()
    {:ok, tx_keys} = Cachex.keys(:transmit)

    our_keys = Enum.filter(tx_keys, fn {pid, _} -> pid == tx_self end)
    # send a wackpk if it's been more than @wack_interval seconds since the last one
    Enum.each(our_keys, fn {_, sequence} ->
      {:ok, packet_state} = Cachex.get(:transmit, {tx_self, sequence})
      %PacketState{wack_count: wack_count, sent_time: sent_time} = packet_state
      {:ok, now} = DateTime.now("Etc/UTC")

      if DateTime.diff(now, sent_time) > @wack_interval do
        Logger.warning("Sending wackpk for sequence: #{sequence}, wackpk count is #{wack_count}")
        state.transport.send(state.socket, Packet.wackpk(sequence))

        case wack_count do
          @wack_threshold ->
            Logger.warning("wackpk threshold reached for sequence: #{sequence}")
            # Too many wackpk's sent, abort the transmission
            send(state.from, {:wp_limit_exceeded, state.socket})

          _ ->
            Cachex.put(
              :transmit,
              {tx_self, sequence},
              %PacketState{
                packet_state
                | wack_count: wack_count + 1,
                  sent_time: now
              }
            )
        end
      end
    end)

    new_state =
      if length(our_keys) > @back_pressure_size do
        state
      else
        case :queue.out(state.packet_queue) do
          {{:value, {packet, sequence}}, new_queue} ->
            Logger.debug("Sending packet with sequence: #{sequence}")
            state.transport.send(state.socket, packet)
            # store the packet in the cache so we can resend it if we get a nakcce or nakncc
            # nakcce_received is false because we haven't sent a nakcce yet
            # wack_count to keep track of how many times we've sent a wackpk
            # now to know when to send a wackpk
            {:ok, now} = DateTime.now("Etc/UTC")

            Cachex.put(:transmit, {tx_self, sequence}, %PacketState{
              nakcce_received: false,
              wack_count: 1,
              sent_time: now,
              packet: packet
            })

            %{state | packet_queue: new_queue}

          {:empty, _packet_queue} ->
            state
        end
      end

    {:noreply, new_state, {:continue, :schedule_run_checks}}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.debug("#{inspect(self())} Transmitter shutting down")
    :ok
  end

  def trim_true([]), do: []
  def trim_true([{_n, true} | tail]), do: trim_true(tail)
  def trim_true([{n, false} | tail]), do: [{n, false} | tail]
end
