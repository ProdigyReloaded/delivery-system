# Copyright 2022-2025, Phillip Heller and Ralph Richard Cook
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

defmodule Prodigy.Server.Service.Sabre.Test do
  @moduledoc false
  use ExUnit.Case

  import Mock

  alias Prodigy.Server.Service.Sabre.{SabreAirGqlClient, SabreAirMapper, SabreData}

  @moduletag :capture_log

  # ===========================================================================
  # SabreData
  # ===========================================================================

  describe "SabreData.airports_map/0" do
    test "returns a non-empty map" do
      map = SabreData.airports_map()
      assert is_map(map)
      assert map_size(map) > 0
    end

    test "contains known major airports" do
      map = SabreData.airports_map()
      assert map["JFK"] == "New York, NY"
      assert map["LAX"] == "Los Angeles, CA"
      assert map["ORD"] == "Chicago, IL"
      assert map["DFW"] == "Dallas-Fort Worth, TX"
    end

    test "returns nil for an unknown code" do
      assert Map.get(SabreData.airports_map(), "ZZZ") == nil
    end
  end

  describe "SabreData.airlines_map/0" do
    test "returns a non-empty map" do
      map = SabreData.airlines_map()
      assert is_map(map)
      assert map_size(map) > 0
    end

    test "contains known major airlines" do
      map = SabreData.airlines_map()
      assert map["AA"] == "American Airlines"
      assert map["DL"] == "Delta Air Lines"
      assert map["UA"] == "United Airlines"
    end

    test "returns nil for an unknown code" do
      assert Map.get(SabreData.airlines_map(), "??") == nil
    end
  end

  # ===========================================================================
  # SabreAirMapper — character/type predicates
  # ===========================================================================

  describe "SabreAirMapper.is_digit/1" do
    test "returns true for digit character codes" do
      assert SabreAirMapper.is_digit(?0)
      assert SabreAirMapper.is_digit(?5)
      assert SabreAirMapper.is_digit(?9)
    end

    test "returns false for non-digit character codes" do
      refute SabreAirMapper.is_digit(?A)
      refute SabreAirMapper.is_digit(?z)
      refute SabreAirMapper.is_digit(?\s)
    end
  end

  describe "SabreAirMapper.is_upper/1" do
    test "returns true for uppercase letter character codes" do
      assert SabreAirMapper.is_upper(?A)
      assert SabreAirMapper.is_upper(?M)
      assert SabreAirMapper.is_upper(?Z)
    end

    test "returns false for lowercase and non-letter codes" do
      refute SabreAirMapper.is_upper(?a)
      refute SabreAirMapper.is_upper(?0)
      refute SabreAirMapper.is_upper(?\s)
    end
  end

  describe "SabreAirMapper.is_booking_class/1" do
    test "accepts a single uppercase letter" do
      assert SabreAirMapper.is_booking_class("Y")
      assert SabreAirMapper.is_booking_class("F")
      assert SabreAirMapper.is_booking_class("Q")
    end

    test "rejects lowercase letters" do
      refute SabreAirMapper.is_booking_class("y")
    end

    test "rejects strings longer than one character" do
      refute SabreAirMapper.is_booking_class("YY")
      refute SabreAirMapper.is_booking_class("AA")
    end

    test "rejects digits and empty strings" do
      refute SabreAirMapper.is_booking_class("1")
      refute SabreAirMapper.is_booking_class("")
    end
  end

  describe "SabreAirMapper.is_passenger_count/1" do
    test "accepts single-digit strings 1-9" do
      assert SabreAirMapper.is_passenger_count("1")
      assert SabreAirMapper.is_passenger_count("9")
    end

    test "rejects multi-digit strings" do
      refute SabreAirMapper.is_passenger_count("10")
    end

    test "rejects letters and empty strings" do
      refute SabreAirMapper.is_passenger_count("A")
      refute SabreAirMapper.is_passenger_count("")
    end
  end

  describe "SabreAirMapper.is_flight_time/1" do
    test "accepts 4-character time strings (HMM + A/P)" do
      assert SabreAirMapper.is_flight_time("600P")
      assert SabreAirMapper.is_flight_time("130A")
    end

    test "accepts 5-character time strings (HHMM + A/P)" do
      assert SabreAirMapper.is_flight_time("1030A")
      assert SabreAirMapper.is_flight_time("1259P")
    end

    test "rejects strings that are not times" do
      refute SabreAirMapper.is_flight_time("AA444")
      refute SabreAirMapper.is_flight_time("1")
      refute SabreAirMapper.is_flight_time("CHICAGO")
    end
  end

  describe "SabreAirMapper.is_flight_number/1" do
    test "accepts two uppercase letters followed by digits" do
      assert SabreAirMapper.is_flight_number("AA444")
      assert SabreAirMapper.is_flight_number("DL1234")
      assert SabreAirMapper.is_flight_number("UA7777")
    end

    test "rejects bare carrier codes with no digits" do
      refute SabreAirMapper.is_flight_number("AA")
    end

    test "rejects time strings" do
      refute SabreAirMapper.is_flight_number("600P")
    end
  end

  describe "SabreAirMapper.is_carrier/1" do
    test "accepts two-character uppercase codes" do
      assert SabreAirMapper.is_carrier("AA")
      assert SabreAirMapper.is_carrier("DL")
    end

    test "accepts codes with a digit (e.g. low-cost carriers)" do
      assert SabreAirMapper.is_carrier("U2")
      assert SabreAirMapper.is_carrier("B6")
    end

    test "rejects codes not exactly two characters" do
      refute SabreAirMapper.is_carrier("A")
      refute SabreAirMapper.is_carrier("AAA")
    end

    test "rejects lowercase codes" do
      refute SabreAirMapper.is_carrier("aa")
    end
  end

  describe "SabreAirMapper.is_connection_city/1" do
    test "accepts strings of 3 or more uppercase letters" do
      assert SabreAirMapper.is_connection_city("NYC")
      assert SabreAirMapper.is_connection_city("CHICAGO")
      assert SabreAirMapper.is_connection_city("DALLAS")
    end

    test "rejects strings shorter than 3 characters" do
      refute SabreAirMapper.is_connection_city("NY")
      refute SabreAirMapper.is_connection_city("A")
    end

    test "rejects lowercase strings" do
      refute SabreAirMapper.is_connection_city("chicago")
    end
  end

  # ===========================================================================
  # SabreAirMapper — time conversion
  # ===========================================================================

  describe "SabreAirMapper.time_to_sabre/1" do
    test "converts midnight (00:00) to 1200A" do
      assert SabreAirMapper.time_to_sabre(~T[00:00:00]) == "1200A"
    end

    test "converts noon (12:00) to 1200P" do
      assert SabreAirMapper.time_to_sabre(~T[12:00:00]) == "1200P"
    end

    test "converts a PM time to space-padded form" do
      assert SabreAirMapper.time_to_sabre(~T[18:00:00]) == " 600P"
    end

    test "converts a four-digit AM time" do
      assert SabreAirMapper.time_to_sabre(~T[10:30:00]) == "1030A"
    end

    test "pads single-digit hours with a leading space" do
      assert SabreAirMapper.time_to_sabre(~T[01:15:00]) == " 115A"
    end

    test "converts 11:59 PM" do
      assert SabreAirMapper.time_to_sabre(~T[23:59:00]) == "1159P"
    end
  end

  describe "SabreAirMapper.mapper_date_format/1" do
    test "formats an ISO date string for terminal display" do
      assert SabreAirMapper.mapper_date_format("2026-10-01") == "Oct 01"
    end

    test "formats December correctly" do
      assert SabreAirMapper.mapper_date_format("2026-12-25") == "Dec 25"
    end

    test "formats January correctly" do
      assert SabreAirMapper.mapper_date_format("2026-01-07") == "Jan 07"
    end
  end

  # ===========================================================================
  # SabreAirMapper — parsing
  # ===========================================================================

  describe "SabreAirMapper.to_map/1" do
    test "parses origin, destination, and date" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,1")
      assert result.type == :airline
      assert result.departure == "JFK"
      assert result.arrival == "LAX"
      assert String.ends_with?(result.date, "-10-01")
    end

    test "parses departure time into ISO 8601 format" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,1")
      assert result.time == "18:00:00"
    end

    test "parses a flight number into carrier and number" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,AA1261,2")
      assert result.carrier == "AA"
      assert result.flight_number == "1261"
    end

    test "parses a standalone carrier code alongside a time" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,DL,1")
      assert result.carrier == "DL"
      assert result.time == "18:00:00"
    end

    test "parses a booking class" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,3,Q")
      assert result.booking_class == "Q"
      assert result.passengers == "3"
    end

    test "parses a connection city" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,DL,2,CHICAGO")
      assert result.connection_city == "CHICAGO"
    end

    test "parses an AM departure time" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,1030A,1")
      assert result.time == "10:30:00"
    end
  end

  describe "SabreAirMapper.list_to_map/2" do
    test "returns the map unchanged for an empty list" do
      base = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
      assert SabreAirMapper.list_to_map(base, []) == base
    end

    test "adds a time entry" do
      base = %{type: :airline}
      result = SabreAirMapper.list_to_map(base, ["600P"])
      assert result.time == "18:00:00"
    end

    test "adds a passenger count entry" do
      base = %{type: :airline}
      result = SabreAirMapper.list_to_map(base, ["2"])
      assert result.passengers == "2"
    end

    test "adds a carrier and flight number from a combined flight number token" do
      base = %{type: :airline}
      result = SabreAirMapper.list_to_map(base, ["UA456"])
      assert result.carrier == "UA"
      assert result.flight_number == "456"
    end

    test "processes multiple tokens in order" do
      base = %{type: :airline}
      result = SabreAirMapper.list_to_map(base, ["600P", "DL", "3", "Q"])
      assert result.time == "18:00:00"
      assert result.carrier == "DL"
      assert result.passengers == "3"
      assert result.booking_class == "Q"
    end
  end

  # ===========================================================================
  # SabreAirMapper — encoding
  # ===========================================================================

  describe "SabreAirMapper.encode_one_flight/1" do
    @flight %{
      "carrier" => "AA",
      "flightNumber" => "1261",
      "origin" => "JFK",
      "dest" => "LAX",
      "departureTime" => "18:00:00",
      "arrivalTime" => "23:03:00"
    }

    test "produces a correctly formatted flight row string" do
      assert SabreAirMapper.encode_one_flight(@flight) ==
               "AA 1261 JFK  600P LAX 1103P R  0 D10  8"
    end

    test "pads short flight numbers with leading spaces" do
      flight = Map.put(@flight, "flightNumber", "56")
      row = SabreAirMapper.encode_one_flight(flight)
      assert String.starts_with?(row, "AA   56 ")
    end

    test "formats AM arrival time correctly" do
      flight = Map.put(@flight, "arrivalTime", "02:30:00")
      row = SabreAirMapper.encode_one_flight(flight)
      assert String.contains?(row, " 230A")
    end
  end

  describe "SabreAirMapper.to_binary/1" do
    test "empty list produces the no-flights-found response" do
      assert SabreAirMapper.to_binary([]) == <<7, 0, 0x01, 0xFF, 0xFF, 0, 0>>
    end

    test "non-empty list produces a response with page code 0x0900" do
      flights = [
        %{
          "carrier" => "AA",
          "flightNumber" => "1261",
          "origin" => "JFK",
          "dest" => "LAX",
          "departureTime" => "18:00:00",
          "arrivalTime" => "23:03:00",
          "date" => "2013-10-01"
        }
      ]

      <<7, 0, 0x01, page_code::16-big, _rest::binary>> = SabreAirMapper.to_binary(flights)
      assert page_code == 0x0900
    end

    test "num_rows in header equals 7 plus the number of flights" do
      one_flight = [%{
        "carrier" => "AA", "flightNumber" => "1261",
        "origin" => "JFK", "dest" => "LAX",
        "departureTime" => "18:00:00", "arrivalTime" => "23:03:00",
        "date" => "2013-10-01"
      }]

      two_flights = one_flight ++ [%{
        "carrier" => "UA", "flightNumber" => "456",
        "origin" => "JFK", "dest" => "LAX",
        "departureTime" => "21:00:00", "arrivalTime" => "01:00:00",
        "date" => "2013-10-01"
      }]

      <<7, 0, 0x01, _::16, rows_1, 0, _::binary>> = SabreAirMapper.to_binary(one_flight)
      <<7, 0, 0x01, _::16, rows_2, 0, _::binary>> = SabreAirMapper.to_binary(two_flights)

      assert rows_1 == 8
      assert rows_2 == 9
    end
  end

  # ===========================================================================
  # SabreAirGqlClient
  # ===========================================================================

  @gql_flight %{
    "carrier" => "AA",
    "flightNumber" => "1261",
    "origin" => "JFK",
    "dest" => "LAX",
    "departureTime" => "18:00:00",
    "arrivalTime" => "23:03:00",
    "date" => "2013-10-01",
    "id" => "1",
    "airline" => %{"name" => "American Airlines"}
  }

  describe "SabreAirGqlClient.handle_request/1" do
    test "returns a list of flight maps on a 200 response" do
      with_mock Req, [post: fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"data" => %{"flights" => [@gql_flight]}}}}
      end] do
        request = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
        result = SabreAirGqlClient.handle_request(request)
        assert length(result) == 1
      end
    end

    test "maps carrier and flight number into the :flight field" do
      with_mock Req, [post: fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"data" => %{"flights" => [@gql_flight]}}}}
      end] do
        request = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
        [flight | _] = SabreAirGqlClient.handle_request(request)
        assert flight.flight == "AA 1261"
      end
    end

    test "converts departure and arrival times to Sabre format" do
      with_mock Req, [post: fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"data" => %{"flights" => [@gql_flight]}}}}
      end] do
        request = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
        [flight | _] = SabreAirGqlClient.handle_request(request)
        assert flight.depart == " 600P"
        assert flight.arrive == "1103P"
      end
    end

    test "maps origin and destination airport codes" do
      with_mock Req, [post: fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"data" => %{"flights" => [@gql_flight]}}}}
      end] do
        request = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
        [flight | _] = SabreAirGqlClient.handle_request(request)
        assert flight.origin == "JFK"
        assert flight.dest == "LAX"
      end
    end

    test "formats the flight date for terminal display" do
      with_mock Req, [post: fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"data" => %{"flights" => [@gql_flight]}}}}
      end] do
        request = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
        [flight | _] = SabreAirGqlClient.handle_request(request)
        assert flight.formatted_date == "OCT 01 13"
      end
    end

    test "assigns an index to each returned flight" do
      second_flight = Map.merge(@gql_flight, %{"flightNumber" => "456", "carrier" => "UA"})

      with_mock Req, [post: fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"data" => %{"flights" => [@gql_flight, second_flight]}}}}
      end] do
        request = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
        [first, second] = SabreAirGqlClient.handle_request(request)
        assert first.index == 0
        assert second.index == 1
      end
    end

    test "returns an empty list on a non-200 HTTP status" do
      with_mock Req, [post: fn _url, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end] do
        request = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
        assert SabreAirGqlClient.handle_request(request) == []
      end
    end

    test "returns an empty list on a network error" do
      with_mock Req, [post: fn _url, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end] do
        request = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
        assert SabreAirGqlClient.handle_request(request) == []
      end
    end

    test "returns an empty list when the response body is malformed" do
      with_mock Req, [post: fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"unexpected" => "structure"}}}
      end] do
        request = %{type: :airline, departure: "JFK", arrival: "LAX", date: "2026-10-01"}
        assert SabreAirGqlClient.handle_request(request) == []
      end
    end
  end
end
