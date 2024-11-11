defmodule Prodigy.Server.Protocol.Tcs.Window do
  @moduledoc """
    TCS Packet Window structures and functions.
    The Window structure holds the the packets that come from the Reception System.
    There is a reception window that can be multiple TCS packets with sequence numbers.
    The Window keeps track of packets with the proper sequence and can request missing
    packets if one is dropped.
  """

  alias __MODULE__

  @sequence_wrap 256

  @receive_window_size 2

  @transmit_window_size 8

  def receive_window_size, do: @receive_window_size

  def transmit_window_size, do: @transmit_window_size

  defstruct [:window_start, :window_size, :sequences, packet_map: %{} ]
  @type t() :: %Window{sequences: list(integer()), window_start: integer(), window_size: integer(), packet_map: Map.t()}

  @spec init(integer(), integer()) :: Prodigy.Server.Protocol.Tcs.Window.t()
  def init(window_start, window_size) do

    # List of sequences in the proper wrap-around order. Important since maps don't preserve key order
    sequences = window_start .. (window_start + window_size - 1) |> Enum.map(fn x -> Integer.mod(x, @sequence_wrap) end)

    packet_map = sequences |> Enum.map(fn x -> {x, :pending} end) |> Map.new

    %Window{window_start: window_start,
      window_size: window_size,
      sequences: sequences,
      packet_map: packet_map}

  end

  @spec add_packet(Prodigy.Server.Protocol.Tcs.Window.t(), integer(), binary()) ::
          {:error, :outside_window} | {:ok, Prodigy.Server.Protocol.Tcs.Window.t()}
  def add_packet(window, sequence_number, packet) do
    if sequence_number in window.sequences do
      new_packet_map = %{window.packet_map | sequence_number => packet}
      {:ok, %Window{window | packet_map: new_packet_map}}
    else
      {:error, :outside_window}
    end
  end

  @spec check_packets(Prodigy.Server.Protocol.Tcs.Window.t()) :: list()
  def check_packets(window) do
    packet_tuples = Enum.map(window.sequences, fn seq -> {seq, window.packet_map[seq]} end)
    Enum.reverse(check_packet(packet_tuples, []))
  end

  def check_packet([{_, _} | []], acc), do: acc

  def check_packet([{seq, pt} | rest], acc) do
    any_remaining_filled = Enum.any?(rest, fn {_s, p} -> p != :pending end)

    new_acc = case({pt, any_remaining_filled}) do
      {:pending, true} -> [{seq, :nakncc} | acc]
      {_, _} -> acc
    end
    check_packet(rest, new_acc)
  end

end
