defmodule Prodigy.Server.Protocol.Tcs.Window do
  @moduledoc """
    TCS Packet Window structures and functions.
    The Window structure holds the the packets that come from the Reception System.
    There is a reception window that can be multiple TCS packets with sequence numbers.
    The Window keeps track of packets with the proper sequence and can request missing
    packets if one is dropped.
  """
  require Logger

  alias __MODULE__
  alias Prodigy.Server.Protocol.Tcs.Packet

  @sequence_wrap 256

  @receive_window_size 2

  @transmit_window_size 8

  def receive_window_size, do: @receive_window_size

  def transmit_window_size, do: @transmit_window_size

  defstruct [:window_start, :window_size, :sequences, packet_map: %{} ]
  @type t() :: %Window{sequences: list(integer()), window_start: integer(), window_size: integer(), packet_map: map()}

  @spec init(integer(), integer()) :: Window.t()
  def init(window_start, window_size) do

    Logger.debug("Initting a window, start=#{window_start}, size=#{window_size}")

    # List of sequences in the proper wrap-around order. Important since maps don't preserve key order
    sequences = window_start .. (window_start + window_size - 1) |> Enum.map(fn x -> Integer.mod(x, @sequence_wrap) end)

    packet_map = sequences |> Enum.map(fn x -> {x, :pending} end) |> Map.new

    %Window{window_start: window_start,
      window_size: window_size,
      sequences: sequences,
      packet_map: packet_map}

  end

  def fetch_value(enumerable, index) do
    case Enum.fetch(enumerable, index) do
      {:ok, value} -> value
      _ -> 0
    end
  end

  @spec first_sequence(Window.t()) :: integer()
  def first_sequence(window), do: fetch_value(window.sequences, 0)

  @spec last_sequence(Window.t()) :: integer()
  def last_sequence(window), do: fetch_value(window.sequences, -1)

  @spec add_packet(integer(), integer(), Packet.t()) ::
          {:ok, Prodigy.Server.Protocol.Tcs.Window.t()}
          | {:error, :outside_window, integer()}
  def add_packet(window, _sequence_number, packet) do
    if packet.seq in window.sequences do
      new_packet_map = %{window.packet_map | packet.seq => packet}
      Logger.debug("add_packet - packet number #{packet.seq} is within range.")
      {:ok, %Window{window | packet_map: new_packet_map}}
    else
      window_first = first_sequence(window)
      window_last = last_sequence(window)
      Logger.warning("add_packet - Received packet with number #{packet.seq}, outside of current window #{window_first} to #{window_last}")
      {:error, :outside_window, window_first}
    end
  end

  @doc """
  Makes a list of tuples of {key, value} of the packet map, in sequence order.
  """
  @spec get_packet_tuples(Window.t()) :: list()
  def get_packet_tuples(window), do: Enum.map(window.sequences, fn seq -> {seq, window.packet_map[seq]} end)


  @doc """
  Returns a list of "missing" packets from a sequence. In this case missing means that
  there is a received packet that has a missing packet, or :pending, in the list of sequences
  that we expect in this window.
  An empty list indicates that there are no out-of-sequence packets.
  """
  @spec check_packets(Window.t()) :: list()
  def check_packets(window) do
    packet_tuples = get_packet_tuples(window)
    checked_packet_list = Enum.reverse(check_packet(packet_tuples, []))
    Logger.debug("Checked packets, out of sequence packets: #{checked_packet_list}")
    checked_packet_list
  end

  @doc """
  Builds the list of out-of-sequence packets. Goes through the list of tuples,
  if a sequence is :pending and there are any after it with received packets then
  you need to send a :nakncc.
  """
  def check_packet([{_, _} | []], acc), do: acc

  def check_packet([{seq, pt} | rest], acc) do
    any_remaining_filled = Enum.any?(rest, fn {_s, p} -> p != :pending end)

    new_acc = case({pt, any_remaining_filled}) do
      {:pending, true} -> [{seq, :nakncc} | acc]
      {_, _} -> acc
    end
    check_packet(rest, new_acc)
  end

  @doc """
  Counts the number of packets used in the window.
  Currently assumes that the TCS packets are filled correctly, from the beginning of the window.
  """
  @spec tcs_packets_used(Window.t()) :: non_neg_integer()
  def tcs_packets_used(window) do
    packet_tuples = get_packet_tuples(window)
    packets_used = Enum.count(packet_tuples, fn {_s, p} -> p != :pending end)
    Logger.debug("Window used #{packets_used} packets out of possible #{Enum.count(window.sequences)}")
    packets_used
  end

end
