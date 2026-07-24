# Copyright 2022-2025, Ralph Richard Cook
#
# This file is part of Prodigy Reloaded.
#
# Prodigy Reloaded is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# Prodigy Reloaded is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with Prodigy Reloaded. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Server.Service.Sabre.SabreAirMapper do
  @moduledoc """
  Maps between Sabre protocol messages and internal representations.

  This module handles parsing of Sabre Air command strings (e.g., `/AIR,JFK,ATL,OCT15,600P,1`)
  into structured maps, and encoding flight data back into Sabre binary protocol format
  for display on legacy terminals.

  ## Sabre Message Format

  The Sabre Air command format is:

      /AIR,<origin>,<dest>,<date>,<time_or_flight>,<optional_params>...

  Where optional parameters can include:
    * Carrier code (2 uppercase letters)
    * Passenger count (single digit)
    * Booking class (single uppercase letter)
    * Connection city (3+ uppercase letters)

  ## Examples

      iex> SabreAirMapper.to_map("/AIR,JFK,ATL,OCT15,600P,1")
      %{type: :airline, departure: "JFK", arrival: "ATL", date: "2026-10-15", time: "18:00:00", passengers: "1"}

      iex> SabreAirMapper.to_map("/AIR,JFK,ATL,OCT15,AA444,3,Q")
      %{type: :airline, departure: "JFK", arrival: "ATL", date: "2026-10-15", carrier: "AA", flight_number: "444", passengers: "3", booking_class: "Q"}
      /AIR,JFK,ATL,OCT15,600P,1
      /AIR,JFK,ATL,OCT15,600P,DL,1
      /AIR,JFK,ATL,OCT15,600P,3,Q
      /AIR,JFK,ATL,OCT15,600P,DL,2,CINCINNATI,Q
      /AIR,JFK,ATL,OCT15,AA444,3,CINCINNATI,Q
      /AIR,JFK,ATL,OCT15,AA7777,3,ROANOKE,X
      /AIR,JFK,ATL,OCT15,600P,DL,3,ROANOKE

  """

  require Logger

  @month_nums %{
    "JAN" => 1,
    "FEB" => 2,
    "MAR" => 3,
    "APR" => 4,
    "MAY" => 5,
    "JUN" => 6,
    "JUL" => 7,
    "AUG" => 8,
    "SEP" => 9,
    "OCT" => 10,
    "NOV" => 11,
    "DEC" => 12
  }

  @num_months %{
    "01" => "Jan",
    "02" => "Feb",
    "03" => "Mar",
    "04" => "Apr",
    "05" => "May",
    "06" => "Jun",
    "07" => "Jul",
    "08" => "Aug",
    "09" => "Sep",
    "10" => "Oct",
    "11" => "Nov",
    "12" => "Dec"
  }

  # @map_swap fn map -> Map.new(map, fn {key, val} -> {val, key} end) end

  # @nums_months @map_swap.(@month_nums)

  # Converts a date string with format "MMMDD" (e.g., "JAN15") to an Elixir Date.
  # The month code should be three uppercase letters (JAN, FEB, etc.)
  # followed by a two-digit day number. Uses the current year for the returned Date.
  defp date_convert(date_string) do
    # Extract month code (first 3 chars) and day (last 2 chars)
    month_code = String.slice(date_string, 0, 3)
    day_string = String.slice(date_string, 3, 2)

    # Convert to integers
    month = month_code_to_number(month_code)
    day = String.to_integer(day_string)

    # Use current year
    year = Date.utc_today().year

    # Create and return the Date
    Date.new!(year, month, day)
  end

  # Takes a date string made with date_convert and formats is as "MonDD" (e.g., "Jan15") for display in Sabre terminal.
  def mapper_date_format(date_string) do
    [_year, month, day] = String.split(date_string, "-")
    @num_months[month] <> " " <> day
  end

  # Converts a time string with format "HHMMA" or "HMMA" (e.g., "130P", "1030A") to an Elixir Time.
  # The string should contain 3 or 4 digits representing the time,
  # followed by "A" for AM or "P" for PM.
  defp time_convert(time_string) do
    # Extract AM/PM indicator (last character)
    am_pm = String.last(time_string)

    # Extract time digits (everything except last character)
    time_digits = String.slice(time_string, 0..-2//1)

    # Parse hour and minute based on length
    {hour, minute} =
      case String.length(time_digits) do
        3 ->
          # Format: HMM (e.g., "130" -> 1:30)
          hour = String.slice(time_digits, 0, 1) |> String.to_integer()
          minute = String.slice(time_digits, 1, 2) |> String.to_integer()
          {hour, minute}

        4 ->
          # Format: HHMM (e.g., "1030" -> 10:30)
          hour = String.slice(time_digits, 0, 2) |> String.to_integer()
          minute = String.slice(time_digits, 2, 2) |> String.to_integer()
          {hour, minute}
      end

    # Convert to 24-hour format
    hour_24 =
      case {hour, am_pm} do
        # 12 AM is midnight (00:xx)
        {12, "A"} -> 0
        # 12 PM is noon (12:xx)
        {12, "P"} -> 12
        # Other PM hours add 12
        {h, "P"} -> h + 12
        # Other AM hours stay the same
        {h, "A"} -> h
      end

    # Create and return the Time
    Time.new!(hour_24, minute, 0)
  end

  defp month_code_to_number(code), do: Map.get(@month_nums, code, 1)

  @doc """
  Converts an Elixir Time struct to Sabre time format (e.g., "130P", "1030A").

  Returns a 5-character string with space padding for single-digit hours.
  """
  def time_to_sabre(%Time{hour: hour_24, minute: minute}) do
    # Convert 24-hour to 12-hour format
    {hour_12, am_pm} =
      case hour_24 do
        # Midnight (00:xx) -> 12 AM
        0 -> {12, "A"}
        # 1-11 AM
        h when h < 12 -> {h, "A"}
        # Noon (12:xx) -> 12 PM
        12 -> {12, "P"}
        # 13-23 -> 1-11 PM
        h -> {h - 12, "P"}
      end

    # Format the time string with proper padding
    time_digits = "#{hour_12}#{String.pad_leading(Integer.to_string(minute), 2, "0")}"

    time_part =
      case hour_12 do
        h when h < 10 -> " " <> time_digits
        _ -> time_digits
      end

    time_part <> am_pm
  end

  @doc """
  Checks if a character code represents a digit (0-9).
  """
  def is_digit(ch), do: ch in ?0..?9

  @doc """
  Checks if a character code represents an uppercase letter (A-Z).
  """
  def is_upper(ch), do: ch in ?A..?Z

  @doc """
  Checks if the string is a valid passenger count (single digit).
  """
  def is_passenger_count(str) do
    String.length(str) == 1 and is_digit(String.to_charlist(str) |> hd())
  end

  @doc """
  Checks if the string is a valid booking class (single uppercase letter).
  """
  def is_booking_class(str) do
    String.length(str) == 1 and is_upper(String.to_charlist(str) |> hd())
  end

  @doc """
  Checks if the string is a valid flight number (2 letter carrier + digits).

  Examples: "AA444", "DL1234", "UA7777"
  """
  def is_flight_number(str) do
    String.length(str) > 2 and
    String.slice(str, 0, 2) |> String.to_charlist() |> Enum.all?(fn ch -> is_upper(ch) end) and
    String.slice(str, 2..-1//1) |> String.to_charlist() |> Enum.all?(fn ch -> is_digit(ch) end)
  end

  @doc """
  Checks if the string is a valid 2-character airline carrier code.

  Carrier codes can contain uppercase letters or digits (e.g., "AA", "DL", "U2").
  """
  def is_carrier(str) do
    String.length(str) == 2 and
    String.to_charlist(str) |> Enum.all?(fn ch -> is_upper(ch) or is_digit(ch) end)
  end

  @doc """
  Checks if the string is a valid connection city (3+ uppercase letters).
  """
  def is_connection_city(str) do
    String.length(str) >= 3 and
    String.to_charlist(str) |> Enum.all?(fn ch -> is_upper(ch) or ch == ?_ end)
  end

  @doc """
  Checks if the string is a valid Sabre flight time (e.g., "600P", "1030A").
  """
  def is_flight_time(str) do
    len = String.length(str)

    (len == 4 or len == 5) and
    String.slice(str, 0, len - 1) |> String.to_charlist() |> Enum.all?(fn ch -> is_digit(ch) end) and
    (String.slice(str, -1, 1) == "A" or String.slice(str, -1, 1) == "P")
  end

  @doc """
  Parses a Sabre Air command string into a structured map.

  ## Examples

      iex> to_map("/AIR,JFK,ATL,OCT15,600P,1")
      %{type: :airline, departure: "JFK", arrival: "ATL", date: "2026-10-15", time: "18:00:00", passengers: "1"}

      iex> to_map("/AIR,JFK,ATL,OCT15,AA444,3,Q")
      %{type: :airline, departure: "JFK", arrival: "ATL", date: "2026-10-15", carrier: "AA", flight_number: "444", passengers: "3", booking_class: "Q"}
  """
  def to_map(sabre_message) do
    parts = String.split(sabre_message, ",")
    [_message_type, departure, arrival, raw_date | rest] = parts

    date = date_convert(raw_date) |> Date.to_string()

    list_to_map(
      %{
        type: :airline,
        departure: departure,
        arrival: arrival,
        date: date
      },
      rest
    )
  end

  @doc """
  Recursively processes a list of Sabre command parts and adds them to the map.

  Each part is identified by type (time, passenger count, booking class, flight number,
  carrier, or connection city) and added to the accumulator map with the appropriate key.
  """
  def list_to_map(map, []) do
    map
  end

  def list_to_map(map, [head | tail]) do
    cond do
      is_flight_time(head) ->
        time = time_convert(head) |> Time.to_string()
        list_to_map(Map.put(map, :time, time), tail)

      is_passenger_count(head) ->
        list_to_map(Map.put(map, :passengers, head), tail)

      is_booking_class(head) ->
        list_to_map(Map.put(map, :booking_class, head), tail)

      is_flight_number(head) ->
        list_to_map(
          Map.put(map, :carrier, String.slice(head, 0, 2))
          |> Map.put(:flight_number, String.slice(head, 2..-1//1)),
          tail
        )

      is_carrier(head) ->
        list_to_map(Map.put(map, :carrier, head), tail)

      is_connection_city(head) ->
        list_to_map(Map.put(map, :connection_city, head), tail)

      true ->
        # Unrecognized part, skip it
        list_to_map(map, tail)
    end
  end

  @doc """
  Encodes a single flight map into a Sabre display row string.

  The output format matches the legacy Sabre terminal display format:
  `"<carrier> <flight#> <origin> <dep_time> <dest> <arr_time> R  0 D10  8"`
  """
  def encode_one_flight(flight) do
    departure_text = Time.from_iso8601!(Map.get(flight, "departureTime")) |> time_to_sabre()
    arrival_text = Time.from_iso8601!(Map.get(flight, "arrivalTime")) |> time_to_sabre()
    padded_flight_number = String.pad_leading(Map.get(flight, "flightNumber"), 4, " ")

    "#{Map.get(flight, "carrier")} #{padded_flight_number} #{Map.get(flight, "origin")} #{departure_text} " <>
      "#{Map.get(flight, "dest")} #{arrival_text} R  0 D10  8"
  end
end
