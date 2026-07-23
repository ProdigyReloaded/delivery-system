# Copyright 2022-2026, Phillip Heller and Ralph Richard Cook
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


defmodule Prodigy.Server.Service.EaasySabre do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Eaasy Sabre requests

  Eaasy Sabre is a terminal-oriented travel reservation system. The service maintains
  state to track where the user is in the application flow. State includes:

  - `current_page` - The page/form currently displayed (determines how to interpret numeric selections)
  - `signed_in` - Whether the user has signed in to Eaasy Sabre
  - `search_results` - Results from flight/car/hotel searches
  - `selected_flights` - Flights selected for the current itinerary
  - `itinerary` - The itinerary being built

  Page codes (bytes 4-5 in response):
  - 0x4700 - Main menu
  - 0x0D03 - Travel reservations menu
  - 0x0200 - Flight search input form
  - 0x0900 - Flight results list
  """

  require Logger

  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context
  alias Prodigy.Server.Service.Sabre.{SabreAirMapper, SabreData}

  # Page codes
  @page_main_menu 0x4700
  @page_travel_reservations 0x0D03
  @page_flight_input 0x0200
  @page_flight_results 0x0900
  @page_select_booking_code 0x1B00
  @page_select_travel_profile 0x2C01
  @page_reservations_made 0x2300
  @page_continue_complete 0x2500
  @page_return_flight_date 0xB903
  @page_itinerary_price 0xBA03

  # Menu definitions: {selection => {description, next_page}}
  # Simple navigational menus that just go to another page
  @main_menu_actions %{
    "2" => {"Travel Reservations", @page_travel_reservations},
    "6" => {"Profile", nil}  # nil = not yet implemented
  }

  @travel_menu_actions %{
    "1" => {"Flight Reservations", @page_flight_input},
    "2" => {"Departure/Arrival Status", nil},
    "3" => {"Hotel Reservations", nil},
    "4" => {"Car Reservations", nil},
    "5" => {"Airline Fares", nil},
    "6" => {"Itinerary Review", nil},
    "8" => {"Flight Schedules", nil},
    "9" => {"Flight Itinerary Details", nil}
  }

  @max_flights 6

  @doc """
  Return the maximum number of flights that can be selected for an itinerary.
  Put here and public so it can be used in other modules.
  """
  def max_flights, do: @max_flights

  @doc """
  Initialize a fresh Eaasy Sabre state.
  """
  def init_state do
    %{
      current_page: nil,
      signed_in: false,
      search_results: nil,
      selected_flights: [],
      current_flight: nil,  # Flight currently being booked (for booking class selection)
      profile_selected: false,  # Whether travel profile has been selected (only shown once)
      itinerary: nil
    }
  end

  # Build a standard response header with the given page code
  defp make_header(page_code, extra \\ <<0, 0>>) do
    <<
      7,
      0,
      0x01,
      page_code::16-big,
      extra::binary
    >>
  end

  # Navigate to a page and update state (state first for piping)
  defp navigate_to(state, page_code) do
    {make_header(page_code), %{state | current_page: page_code}}
  end

  # Reset transient state (search results, selections, itinerary)
  defp reset_transient(state) do
    %{state | search_results: nil, selected_flights: [], current_flight: nil, profile_selected: false, itinerary: nil}
  end

  # Format flight info for the booking code selection page.
  #
  # Returns a 114-byte string (3 rows x 38 columns) formatted as:
  #   "Flight: AIRLINE NAME          FLNUM    "
  #   "Depart: CITY NAME              TIME    "
  #   "Arrive: CITY NAME              TIME    "
  #
  # Layout per row: label (8) + name (20, left) + space (1) + value (5) + padding (4) = 38
  # Flight number is left-justified, times are right-justified in their 5-char field.
  defp format_flight_info(flight) do
    # Parse airline code and flight number from "AA 1261" format
    [airline_code | rest] = String.split(flight.flight, " ", parts: 2)
    flight_num = rest |> List.first() |> String.trim()

    # Look up full names (with fallbacks)
    airline_name = Map.get(SabreData.airlines_map(), airline_code, airline_code)
    origin_city = Map.get(SabreData.airports_map(), flight.origin, flight.origin)
    dest_city = Map.get(SabreData.airports_map(), flight.dest, flight.dest)

    # Format each row to exactly 38 characters
    flight_row = format_row("Flight: ", airline_name, flight_num, :left)
    depart_row = format_row("Depart: ", origin_city, flight.depart, :right)
    arrive_row = format_row("Arrive: ", dest_city, flight.arrive, :right)

    flight_row <> depart_row <> arrive_row
  end

  # Format a single 38-character row
  # Layout: label (8) + name (20, left-justified) + space (1) + value (5) + padding (4) = 38
  # align parameter controls whether value is :left or :right justified in its 5-char field
  defp format_row(label, name, value, align) do
    padded_name = name |> String.slice(0, 20) |> String.pad_trailing(20)
    padded_value = case align do
      :left -> value |> String.slice(0, 5) |> String.pad_trailing(5)
      :right -> value |> String.slice(0, 5) |> String.pad_leading(5)
    end
    label <> padded_name <> " " <> padded_value <> "    "
  end

  # Field IDs for booking class display (up to 8 classes)
  @booking_class_display_fields [0x20, 0x25, 0x2A, 0x34, 0x52, 0x5C, 0x61, 0x66]
  # Field IDs for booking class selection (up to 8 classes)
  @booking_class_selection_fields [0x9775, 0xFB75, 0x5F76, 0xC376, 0xB778, 0x1B79, 0x7F79, 0xE379]

  # Build booking class display and selection fields for a flight
  # Returns {display_fields_binary, selection_fields_binary, class_count}
  defp build_booking_class_fields(booking_classes) do
    # Take up to 8 booking classes
    classes = Enum.take(booking_classes, 8)

    # Build display fields (show the class letter)
    display_fields = classes
    |> Enum.with_index()
    |> Enum.map(fn {class, idx} ->
      field_id = Enum.at(@booking_class_display_fields, idx)
      <<field_id, 0x4E, 0, 1, class::binary>>
    end)
    |> Enum.join()

    # Build selection fields (show the selection number 1-8)
    selection_fields = classes
    |> Enum.with_index(1)
    |> Enum.map(fn {_class, selection_num} ->
      field_id = Enum.at(@booking_class_selection_fields, selection_num - 1)
      selection_str = Integer.to_string(selection_num)
      len = byte_size(selection_str)
      <<field_id::16-big, 0, len, selection_str::binary>>
    end)
    |> Enum.join()

    {display_fields, selection_fields, length(classes)}
  end

  # Field IDs for reservations made page (up to 3 flights)
  # Each flight has: {booking_code_field, date_field, details_field}
  @reservation_flight_fields [
    {0x1027, 0x0B00, 0x0C00},  # Flight 1
    {0x1527, 0x0E00, 0x0F00},  # Flight 2
    {0x1A27, 0x1100, 0x1200}   # Flight 3
  ]

  # Format flight details for the reservations made page
  # Returns a 90-byte string (3 rows x 30 columns):
  #   "AIRLINE NAME          FLNUM   "
  #   "(XXX) CITY, ST              "
  #   "(XXX) CITY, ST              "
  defp format_reservation_flight_details(flight) do
    # Parse airline code and flight number
    [airline_code | rest] = String.split(flight.flight, " ", parts: 2)
    flight_num = rest |> List.first() |> String.trim()

    # Look up full names
    airline_name = Map.get(SabreData.airlines_map(), airline_code, airline_code)
    origin_city = Map.get(SabreData.airports_map(), flight.origin, flight.origin)
    dest_city = Map.get(SabreData.airports_map(), flight.dest, flight.dest)

    # Row 1: airline name (20 chars) + space + flight number (9 chars) = 30
    row1 = (airline_name |> String.slice(0, 20) |> String.pad_trailing(20)) <>
           " " <>
           (flight_num |> String.slice(0, 9) |> String.pad_trailing(9))

    # Row 2: (XXX) CITY, ST padded to 30 chars
    row2 = "(#{flight.origin}) #{origin_city}" |> String.slice(0, 30) |> String.pad_trailing(30)

    # Row 3: (XXX) CITY, ST padded to 30 chars
    row3 = "(#{flight.dest}) #{dest_city}" |> String.slice(0, 30) |> String.pad_trailing(30)

    row1 <> row2 <> row3
  end

  # Build the reservations made page response for the given flights
  # Supports 1-3 flights
  defp build_reservations_response(flights) do
    # Reverse to show in order they were added (selected_flights is a stack)
    flights_in_order = Enum.reverse(flights) |> Enum.take(3)
    flight_count = length(flights_in_order)

    # Build fields for each flight
    flight_fields = flights_in_order
    |> Enum.with_index()
    |> Enum.map(fn {flight, idx} ->
      {code_field, date_field, details_field} = Enum.at(@reservation_flight_fields, idx)

      booking_code = Map.get(flight, :selected_class, "Y")
      date_str = Map.get(flight, :formatted_date, "N/A") |> String.slice(0, 13) |> String.pad_trailing(13)
      details = format_reservation_flight_details(flight)

      <<
        code_field::16-big, 0, 1, booking_code::binary,
        date_field::16-big, 0, 13, date_str::binary,
        details_field::16-big, 0, 90, details::binary
      >>
    end)
    |> Enum.join()

    # Total fields: 3 per flight (code, date, details)
    field_count = flight_count * 3

    <<
      7, 0, 0x01,
      @page_reservations_made::16-big,
      field_count, 0,
      flight_fields::binary
    >>
  end

  # Build the itinerary price page response
  # Field layout (from page analysis):
  #   Your tickets, including tax, will cost:
  #   [a:10]  [b:7]  [c:3]      - First fare line
  #   [d:10]  [e:24]            - First segment details
  #   [f:10]  [g:7]  [h:3]      - Second fare line
  #   [i:10]  [j:24]            - Second segment details
  #   Total fare:  [k:7]  [l:3] - Total
  #   [m:39x2]                  - Notes (2 rows)
  #   [n:19] [o:7]              - Additional info
  #   [p:23]                    - More info
  #   [q:37]                    - Final note
  defp build_itinerary_price_response(flights) do
    # Field layout based on text-mode Eaasy Sabre example:
    #   Your airline tickets, including any applicable taxes, will cost:
    #   [a:Each adult:]  [b: 947.88]  [c:USD]     <- only if adult fares
    #   [d:Fare codes:]  [e:M, Y                     ]
    #   [f:Each child:]  [g: amount]  [h:USD]     <- only if child fares
    #   [i:Fare codes:]  [j:codes                    ]
    #   Total fare:  [k: 947.88]  [l:USD]
    #   [m: You saved... (only if bargain finder used)]
    #   [n:????????????????????] [o:????????]
    #   [p:?????????????????????]
    #   [q:??????????????????????????????????????]
    #
    # Field widths:
    #   a, d, f, i = 11 chars (labels with colon)
    #   b, g, k, o = 8 chars (amounts)
    #   c, h, l = 3 chars (currency)
    #   e, j = 25 chars (fare codes)
    #   m = 2 rows × 40 chars = 80 chars (savings message)
    #   n = 20 chars, p = 23 chars, q = 38 chars

    # Calculate fare from selected flights' booking classes
    # For now, use placeholder pricing
    base_fare = 299.00
    fare_per_adult = base_fare * length(flights)

    # Get fare codes from selected flights
    fare_codes = flights
    |> Enum.reverse()
    |> Enum.map(&Map.get(&1, :selected_class, "Y"))
    |> Enum.join(", ")

    # For now, we always have 1 adult, no children, no bargain finder
    has_adult_fares = true
    has_child_fares = false
    used_bargain_finder = false

    # Build adult fare fields (a, b, c, d, e) - only if adult fares present
    adult_fields = if has_adult_fares do
      field_a = "Each adult:" |> String.pad_trailing(11)
      field_b = :io_lib.format("~8.2f", [fare_per_adult]) |> to_string()
      field_c = "USD"
      field_d = "Fare codes:" |> String.pad_trailing(11)
      field_e = fare_codes |> String.pad_trailing(25)
      <<
        0x06, 0x00, 0, 11, field_a::binary,
        0x02, 0x00, 0, 8, field_b::binary,
        0x04, 0x00, 0, 3, field_c::binary,
        0x0d, 0x00, 0, 11, field_d::binary,
        0x0b, 0x00, 0, 25, field_e::binary
      >>
    else
      <<>>
    end

    # Build child fare fields (f, g, h, i, j) - only if child fares present
    child_fields = if has_child_fares do
      field_f = "Each child:" |> String.pad_trailing(11)
      field_g = :io_lib.format("~8.2f", [0.0]) |> to_string()  # placeholder
      field_h = "USD"
      field_i = "Fare codes:" |> String.pad_trailing(11)
      field_j = "" |> String.pad_trailing(25)  # placeholder
      <<
        0x07, 0x00, 0, 11, field_f::binary,
        0x03, 0x00, 0, 8, field_g::binary,
        0x05, 0x00, 0, 3, field_h::binary,
        0x0c, 0x00, 0, 11, field_i::binary,
        0x0e, 0x00, 0, 25, field_j::binary
      >>
    else
      <<>>
    end

    # Build savings message (m) - only if bargain finder was used
    savings_fields = if used_bargain_finder do
      field_m = "You saved a total of   152.00  over the " <>
                "regular coach fare.                     "  # 80 chars
      <<0x0a, 0x00, 0, 80, field_m::binary>>
    else
      <<>>
    end

    # Total fare fields (k, l) - always present
    field_k = :io_lib.format("~8.2f", [fare_per_adult]) |> to_string()
    field_l = "USD"
    total_fields = <<
      0x0f, 0x00, 0, 8, field_k::binary,
      0x10, 0x00, 0, 3, field_l::binary
    >>

    # Unknown fields (n, o, p, q) - leave blank for now
    field_n = String.duplicate(" ", 20)
    field_o = String.duplicate(" ", 8)
    field_p = String.duplicate(" ", 23)
    field_q = String.duplicate(" ", 38)
    unknown_fields = <<
      0x08, 0x00, 0, 20, field_n::binary,
      0x09, 0x00, 0, 8, field_o::binary,
      0x11, 0x00, 0, 23, field_p::binary,
      0x14, 0x00, 0, 38, field_q::binary
    >>

    # Count fields included
    adult_field_count = if has_adult_fares, do: 5, else: 0
    child_field_count = if has_child_fares, do: 5, else: 0
    savings_field_count = if used_bargain_finder, do: 1, else: 0
    total_field_count = 2  # k, l
    unknown_field_count = 4  # n, o, p, q
    field_count = adult_field_count + child_field_count + savings_field_count + total_field_count + unknown_field_count

    <<
      7, 0, 0x01,
      @page_itinerary_price::16-big,
      field_count, 0,
      adult_fields::binary,
      child_fields::binary,
      total_fields::binary,
      savings_fields::binary,
      unknown_fields::binary
    >>
  end

  # Format a flight result row for display (39 chars)
  # Format: "AA 1261 DFW  620P LAX 1103P R  0 D10  8"
  defp format_flight_result_row(flight) do
    # Build the 39-char display string
    flight_code = flight.flight |> String.pad_trailing(7)
    origin = flight.origin |> String.pad_trailing(4)
    depart = flight.depart |> String.pad_trailing(5)
    dest = flight.dest |> String.pad_trailing(4)
    arrive = flight.arrive |> String.pad_trailing(5)
    # R/L for meal type, stops, equipment, meal code
    stops = Integer.to_string(flight.stops)
    equip = flight.equip |> String.pad_trailing(5)
    meal = flight.meal

    "#{flight_code} #{origin}#{depart} #{dest}#{arrive} R  #{stops} #{equip}#{meal}"
    |> String.slice(0, 39)
    |> String.pad_trailing(39)
  end

  # Format booking classes for display (space-separated, 3 chars each)
  defp format_booking_classes(classes) do
    classes
    |> Enum.map(&String.pad_trailing(&1, 3))
    |> Enum.join()
    |> String.trim_trailing()
  end

  # Build flight results page response
  defp build_flight_results_response(search_results, date_display) do
    # Build flight display rows (fields 0x10, 0x11, etc.)
    flight_rows = search_results
    |> Enum.with_index()
    |> Enum.map(fn {flight, idx} ->
      field_id = 0x10 + idx
      row = format_flight_result_row(flight)
      <<field_id, 0x27, 0, 39, row::binary>>
    end)
    |> Enum.join()

    # Build selection number fields (0x75, 0xD9, etc.)
    selection_field_ids = [0x7527, 0xD927, 0x3D28, 0xA128, 0x0529, 0x6929]  # Up to 6 flights
    selection_fields = search_results
    |> Enum.with_index(1)
    |> Enum.map(fn {_flight, num} ->
      field_id = Enum.at(selection_field_ids, num - 1)
      num_str = Integer.to_string(num)
      <<field_id::16-big, 0x00, byte_size(num_str), num_str::binary>>
    end)
    |> Enum.join()

    # Build flight code display fields (0xE2, 0x38, etc.)
    code_field_ids = [0xE2, 0x38, 0x42, 0x4C, 0x56, 0x60]  # Up to 6 flights
    code_fields = search_results
    |> Enum.with_index()
    |> Enum.map(fn {flight, idx} ->
      field_id = Enum.at(code_field_ids, idx)
      code = flight.flight
      <<field_id, 0x27, 0, byte_size(code), code::binary>>
    end)
    |> Enum.join()

    # Build booking class display fields (0x6A, 0x6B, etc.)
    class_field_ids = [0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F]  # Up to 6 flights
    class_fields = search_results
    |> Enum.with_index()
    |> Enum.map(fn {flight, idx} ->
      field_id = Enum.at(class_field_ids, idx)
      classes = format_booking_classes(flight.booking_classes)
      <<field_id, 0x27, 0, byte_size(classes), classes::binary>>
    end)
    |> Enum.join()

    # Total field count: 1 (date) + flights * 4 (row, selection, code, classes)
    field_count = 1 + length(search_results) * 4

    <<
      7, 0, 0x01,
      @page_flight_results::16-big,
      field_count, 0,
      0x24, 0x27, 0, byte_size(date_display), date_display::binary,
      flight_rows::binary,
      selection_fields::binary,
      code_fields::binary,
      class_fields::binary
    >>
  end

  # ============================================================================
  # Global Commands (work from any page, start with "/")
  # ============================================================================

  defp int_handle("/SIGNON" <> _rest, _state) do
    Logger.info("Eaasy Sabre: SIGNON")
    new_state = %{init_state() | signed_in: true, current_page: @page_main_menu}
    {make_header(@page_main_menu), new_state}
  end

  defp int_handle("/SIGNOFF" <> _rest, _state) do
    Logger.info("Eaasy Sabre: SIGNOFF")
    {<<0x0>>, init_state()}
  end

  # /E - Return to system operator (exit Eaasy Sabre)
  defp int_handle("/E" <> _rest, _state) do
    Logger.info("Eaasy Sabre: Exit (return to system operator)")
    {<<0x0>>, init_state()}
  end

  defp int_handle("/M" <> _rest, state) do
    Logger.info("Eaasy Sabre: Main Menu")
    state |> reset_transient() |> navigate_to(@page_main_menu)
  end

  defp int_handle("/T" <> _rest, state) do
    Logger.info("Eaasy Sabre: Top")
    state |> reset_transient() |> navigate_to(@page_main_menu)
  end


  # send some flight options
  defp int_handle("/AIR," <> <<rest::binary>> = message, state) do
    # split rest on , to get the input values
    Logger.info("Eaasy Sabre: AIR search - #{rest}")

    client_map = SabreAirMapper.to_map(message)
    client_module = Application.get_env(:server, :sabre_air_client)
    search_results = client_module.handle_request(client_map)
    Logger.info("retrieved flights: #{inspect(search_results)}")

    # each flight in search_results should have a formatted_date field
    # If no flights returned, use the search date for display (formatted as "OCT 01 91")
    date_display = cond do
      length(search_results) > 0 ->
        List.first(search_results).formatted_date
      true ->
        SabreAirMapper.mapper_date_format(client_map[:date])
    end

    new_state = %{state |
      current_page: @page_flight_results,
      search_results: search_results
    }

    response = build_flight_results_response(search_results, date_display)

    {response, new_state}
  end

  defp int_handle("/RULES" <> _rest, state) do
    Logger.info("Eaasy Sabre: RULES")
    # TODO: Implement rules display
    {<<0>>, state}
  end

  # /PRICE - Show itinerary price (only valid when reservation in progress)
  defp int_handle("/PRICE" <> _rest, %{selected_flights: flights} = state)
       when flights != [] do
    Logger.info("Eaasy Sabre: PRICE - showing itinerary price")
    new_state = %{state | current_page: @page_itinerary_price}
    response = build_itinerary_price_response(flights)
    {response, new_state}
  end

  defp int_handle("/PRICE" <> _rest, state) do
    Logger.warning("Eaasy Sabre: PRICE requested but no reservation in progress")
    {<<0>>, state}
  end

  # ============================================================================
  # Menu-based selections (lookup in menu maps)
  # ============================================================================

  defp int_handle(selection, %{current_page: @page_main_menu} = state) do
    Logger.debug("Eaasy Sabre: int_handle Main Menu selection #{inspect(selection)}")
    handle_menu_selection(selection, @main_menu_actions, "Main Menu", state)
  end

  defp int_handle(selection, %{current_page: @page_travel_reservations} = state) do
    Logger.debug("Eaasy Sabre: int_handle Travel Reservations selection #{inspect(selection)}")
    handle_menu_selection(selection, @travel_menu_actions, "Travel Reservations", state)
  end

  # ============================================================================
  # Special handlers (non-simple navigation)
  # ============================================================================

  # Flight results - numeric selection picks a flight
  defp int_handle(selection, %{current_page: @page_flight_results, search_results: results} = state)
       when results != nil do
    Logger.debug("Eaasy Sabre: int_handle Flight Results selection #{inspect(selection)}")
    case Integer.parse(selection) do
      {index, ""} when index >= 1 ->
        case Enum.at(results, index - 1) do
          nil ->
            Logger.warning("Eaasy Sabre: Invalid flight selection #{index}")
            {<<0>>, state}

          flight ->
            Logger.info("Eaasy Sabre: Selected flight #{inspect(flight)}")
            new_state = %{state |
              current_page: @page_select_booking_code,
              current_flight: flight
            }

            flight_info = format_flight_info(flight)
            {display_fields, selection_fields, class_count} = build_booking_class_fields(flight.booking_classes)

            # Total fields: 1 (flight info) + class_count (display) + 1 (date) + class_count (selection)
            field_count = 2 + class_count * 2

            formatted_flight_date = Map.get(flight, :formatted_date, "N/A   ") |> String.slice(0, 6)

            response = <<
              7, 0, 0x01,
              @page_select_booking_code::16-big,
              field_count, 0,
              0x10, 0x27, 0, 114, flight_info::binary,
              display_fields::binary,
              0x4C, 0x27, 0, 6, formatted_flight_date::binary,
              selection_fields::binary
            >>

            {response, new_state}
        end

      _ ->
        Logger.warning("Eaasy Sabre: Invalid selection on flight results: #{inspect(selection)}")
        {<<0>>, state}
    end
  end

  # Booking class selection - numeric selection picks a fare class
  defp int_handle(selection, %{current_page: @page_select_booking_code, current_flight: flight, profile_selected: profile_selected} = state)
       when flight != nil do
    Logger.debug("Eaasy Sabre: int_handle Booking Class selection #{inspect(selection)} for flight #{inspect(flight.flight)}")
    case Integer.parse(selection) do
      {index, ""} when index >= 1 and index <= length(flight.booking_classes) ->
        selected_class = Enum.at(flight.booking_classes, index - 1)
        Logger.info("Eaasy Sabre: Selected booking class #{selected_class} for flight #{flight.flight}")

        # Add the flight with selected booking class to selected_flights
        booked_flight = Map.put(flight, :selected_class, selected_class)
        updated_flights = [booked_flight | state.selected_flights]

        # If profile already selected, skip to reservations made; otherwise show travel profile
        if profile_selected do
          Logger.info("Eaasy Sabre: Profile already selected, going to reservations made")
          new_state = %{state |
            selected_flights: updated_flights,
            current_flight: nil,
            current_page: @page_reservations_made
          }
          response = build_reservations_response(updated_flights)
          {response, new_state}
        else
          Logger.info("Eaasy Sabre: Showing travel profile selection")
          new_state = %{state |
            selected_flights: updated_flights,
            current_flight: nil,
            current_page: @page_select_travel_profile
          }
          response = <<
            7, 0, 0x01,
            @page_select_travel_profile::16-big,
            0, 0
          >>
          {response, new_state}
        end

      _ ->
        Logger.warning("Eaasy Sabre: Invalid booking class selection: #{inspect(selection)}")
        {<<0>>, state}
    end
  end

  # Return flight date input - expects date like "OCT14"
  # Responds with flight results with origin/dest swapped from first selected flight
  defp int_handle(date_input, %{current_page: @page_return_flight_date, selected_flights: flights} = state)
       when flights != [] do
    Logger.debug("Eaasy Sabre: int_handle Return Flight Date input #{inspect(date_input)}")
    # Get the first flight (most recently added, at head of list)
    first_flight = hd(flights)

    # Swap origin and destination for return flight
    origin = first_flight.dest
    dest = first_flight.origin

    Logger.info("Eaasy Sabre: Return flight date #{date_input} - searching #{origin} to #{dest}")


    # Get flights with swapped origin/destination
    return_flight_text = "/AIR,#{origin},#{dest},#{date_input}"

    client_map = SabreAirMapper.to_map(return_flight_text)
    client_module = Application.get_env(:server, :sabre_air_client)
    search_results = client_module.handle_request(client_map)

    new_state = %{state | current_page: @page_flight_results, search_results: search_results}

    # each flight in search_results should have a formatted_date field
    # If no flights returned, use the search date for display (formatted as "OCT 01 91")
    date_display = cond do
      length(search_results) > 0 ->
        List.first(search_results).formatted_date
      true ->
        SabreAirMapper.mapper_date_format(client_map[:date])
    end

    response = build_flight_results_response(search_results, date_display)

    {response, new_state}
  end

  # Travel profile selection - "1" uses regular travel profile
  defp int_handle("1", %{current_page: @page_select_travel_profile, selected_flights: flights} = state)
       when flights != [] do
    Logger.info("Eaasy Sabre: Using regular travel profile")

    new_state = %{state | current_page: @page_reservations_made, profile_selected: true}
    response = build_reservations_response(flights)

    {response, new_state}
  end

  # Reservations made page selections
  defp int_handle(selection, %{current_page: @page_reservations_made, selected_flights: flights} = state) do
    Logger.debug("Eaasy Sabre: int_handle Reservations Made selection #{inspect(selection)}")
    case selection do
      # View flight 1 details
      "1" when length(flights) >= 1 ->
        Logger.info("Eaasy Sabre: View flight 1 details (not implemented)")
        # TODO: Navigate to flight details page
        {<<0>>, state}

      # View flight 2 details
      "2" when length(flights) >= 2 ->
        Logger.info("Eaasy Sabre: View flight 2 details (not implemented)")
        # TODO: Navigate to flight details page
        {<<0>>, state}

      # View flight 3 details
      "3" when length(flights) >= 3 ->
        Logger.info("Eaasy Sabre: View flight 3 details (not implemented)")
        # TODO: Navigate to flight details page
        {<<0>>, state}

      # Correct/Continue - advance to complete request
      "4" ->
        Logger.info("Eaasy Sabre: Continue/Complete request")
        new_state = %{state | current_page: @page_continue_complete}
        response = <<
          7, 0, 0x01,
          @page_continue_complete::16-big,
          0, 0
        >>
        {response, new_state}

      # Cancel this flight request
      "5" ->
        Logger.info("Eaasy Sabre: Cancel flight request")
        new_state = state |> reset_transient() |> Map.put(:current_page, @page_travel_reservations)
        {make_header(@page_travel_reservations), new_state}

      _ ->
        Logger.warning("Eaasy Sabre: Invalid selection on reservations made: #{inspect(selection)}")
        {<<0>>, state}
    end
  end

  # Continue/Complete request page selections
  defp int_handle(selection, %{current_page: @page_continue_complete} = state) do
    Logger.debug("Eaasy Sabre: int_handle Continue/Complete selection #{inspect(selection)}")
    case selection do
      # Add a return flight (roundtrip) - goes to return flight date page
      "1" ->
        Logger.info("Eaasy Sabre: Add return flight (roundtrip)")
        new_state = %{state | current_page: @page_return_flight_date}
        response = <<
          7, 0, 0x01,
          @page_return_flight_date::16-big,
          0, 0
        >>
        {response, new_state}

      # Add a continuing flight
      "2" ->
        Logger.info("Eaasy Sabre: Add continuing flight")
        # TODO: Navigate to flight input page with appropriate context
        {<<0>>, state}

      # Add a car reservation
      "3" ->
        Logger.info("Eaasy Sabre: Add car reservation")
        # TODO: Navigate to car reservation input page
        {<<0>>, state}

      # Add a hotel reservation
      "4" ->
        Logger.info("Eaasy Sabre: Add hotel reservation")
        # TODO: Navigate to hotel reservation input page
        {<<0>>, state}

      # Request complete
      "5" ->
        Logger.info("Eaasy Sabre: Request complete")
        # TODO: Finalize reservation and navigate to confirmation page
        {<<0>>, state}

      _ ->
        Logger.warning("Eaasy Sabre: Invalid selection on continue/complete: #{inspect(selection)}")
        {<<0>>, state}
    end
  end

  # ============================================================================
  # Fallback handlers
  # ============================================================================

  # Handle selections when no page context (legacy/initial state)
  defp int_handle("2", %{current_page: nil} = state) do
    Logger.info("Eaasy Sabre: (no page context) assuming main menu -> Travel Reservations")
    navigate_to(state, @page_travel_reservations)
  end

  defp int_handle("1", %{current_page: nil} = state) do
    Logger.info("Eaasy Sabre: (no page context) assuming travel menu -> Flight Input")
    navigate_to(state, @page_flight_input)
  end

  # Catch-all for unhandled commands
  defp int_handle(payload, state) do
    Logger.warning(
      "Eaasy Sabre: unhandled request on page #{inspect(state.current_page, base: :hex)}: #{inspect(payload, base: :hex, limit: :infinity)}"
    )
    {<<0>>, state}
  end

  # ============================================================================
  # Helper for menu-based navigation
  # ============================================================================

  defp handle_menu_selection(selection, menu_actions, menu_name, state) do
    case Map.get(menu_actions, selection) do
      {description, nil} ->
        Logger.info("Eaasy Sabre: #{menu_name} -> #{description} (not implemented)")
        {<<0>>, state}

      {description, next_page} ->
        Logger.info("Eaasy Sabre: #{menu_name} -> #{description}")
        navigate_to(state, next_page)

      nil ->
        Logger.warning("Eaasy Sabre: Unknown selection '#{selection}' on #{menu_name}")
        {<<0>>, state}
    end
  end

  # ============================================================================
  # Main entry point
  # ============================================================================

  def handle(%Fm0{dest: 0x063201, payload: payload} = request, %Context{} = context) do
    Logger.debug("Eaasy Sabre RX: #{inspect(payload, limit: :infinity)}")

    # Initialize state if not present
    es_state = context.eaasy_sabre || init_state()

    # Trim whitespace from payload before processing (unless it's a slash command)
    normalized_payload = if String.starts_with?(payload, "/") do
      payload
    else
      String.trim(payload)
    end

    # Process the request
    {response_payload, es_state} = int_handle(normalized_payload, es_state)

    Logger.debug("Eaasy Sabre TX: #{inspect(response_payload, limit: :infinity, base: :hex)}")
    Logger.debug("Eaasy Sabre state: #{inspect(es_state)}")

    # Update context with new state
    context = %{context | eaasy_sabre: es_state}

    response = %{
      request
      | concatenated: false,
        src: request.dest,
        dest: request.src,
        mode: %Fm0.Mode{response: true},
        fm4: nil,
        fm9: nil,
        fm64: nil,
        payload: response_payload
    }

    {:ok, context, DiaPacket.encode(response)}
  end
end
