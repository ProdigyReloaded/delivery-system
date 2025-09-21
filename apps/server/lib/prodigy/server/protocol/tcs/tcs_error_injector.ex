defmodule Prodigy.Server.Protocol.Tcs.ErrorInjector do
  @moduledoc """
  Module for injecting bit errors into TCS packets for testing error handling.
  Can be used to simulate transmission errors.
  """

  require Logger
  import Bitwise

  defstruct [
    enabled: false,
    error_rate: 0.0,
    error_types: [:bit_flip, :byte_corruption, :truncation],
    target: :both,
    excluded_types: []
  ]

  def init(opts \\ []) do
    %__MODULE__{
      enabled: Keyword.get(opts, :enabled, false),
      error_rate: Keyword.get(opts, :error_rate, 0.01),
      error_types: Keyword.get(opts, :error_types, [:bit_flip]),
      target: Keyword.get(opts, :target, :both),
      excluded_types: Keyword.get(opts, :excluded_types, [])
    }
  end

  def maybe_corrupt(data, config, direction \\ :send) do
    # Don't try to corrupt empty data
    if byte_size(data) == 0 do
      data
    else
      if should_inject_error?(config, direction) do
        corrupt_data(data, config)
      else
        data
      end
    end
  end

  defp should_inject_error?(%{enabled: false}, _), do: false
  defp should_inject_error?(%{target: :send}, :receive), do: false
  defp should_inject_error?(%{target: :receive}, :send), do: false
  defp should_inject_error?(%{error_rate: rate}, _) do
    :rand.uniform() < rate
  end

  defp corrupt_data(data, %{error_types: types}) do
    error_type = Enum.random(types)
    corrupted = apply_corruption(data, error_type)

    Logger.warning("ErrorInjector: Applied #{error_type} corruption to packet")
    corrupted
  end

  defp apply_corruption(data, :bit_flip) do
    bytes = :binary.bin_to_list(data)
    if length(bytes) == 0 do
      data
    else
      position = :rand.uniform(length(bytes)) - 1
      byte = Enum.at(bytes, position)
      bit_position = :rand.uniform(8) - 1
      flipped_byte = bxor(byte, bsl(1, bit_position))

      bytes
      |> List.replace_at(position, flipped_byte)
      |> :binary.list_to_bin()
    end
  end

  defp apply_corruption(data, :byte_corruption) do
    bytes = :binary.bin_to_list(data)
    if length(bytes) == 0 do
      data
    else
      position = :rand.uniform(length(bytes)) - 1
      corrupted_byte = :rand.uniform(256) - 1

      bytes
      |> List.replace_at(position, corrupted_byte)
      |> :binary.list_to_bin()
    end
  end

  defp apply_corruption(data, :truncation) do
    size = byte_size(data)
    if size <= 1 do
      # Can't truncate empty or single-byte data meaningfully
      data
    else
      # Remove 1 to min(5, size-1) bytes from the end
      bytes_to_remove = :rand.uniform(min(5, size - 1))
      new_size = size - bytes_to_remove
      binary_part(data, 0, new_size)
    end
  end

  defp apply_corruption(data, :duplication) do
    size = byte_size(data)
    if size <= 1 do
      # Can't duplicate meaningfully with tiny data
      data
    else
      position = :rand.uniform(max(1, size - 1))
      dup_size = :rand.uniform(min(5, max(1, size - position)))

      <<prefix::binary-size(position), dup::binary-size(dup_size), rest::binary>> = data
      <<prefix::binary, dup::binary, dup::binary, rest::binary>>
    end
  end

  defp apply_corruption(data, :noise) do
    noise_count = :rand.uniform(5)
    noise = for _ <- 1..noise_count, into: <<>>, do: <<:rand.uniform(256) - 1>>

    size = byte_size(data)
    if size == 0 do
      # Just prepend noise if data is empty
      <<noise::binary, data::binary>>
    else
      position = :rand.uniform(size) - 1
      <<prefix::binary-size(position), rest::binary>> = data
      <<prefix::binary, noise::binary, rest::binary>>
    end
  end
end