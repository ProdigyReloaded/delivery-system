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

defmodule Prodigy.Server.Service.EaasySabre.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase

  require Logger

  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router
  alias Prodigy.Server.Service.Sabre.SabreAirMapper

  @moduletag :capture_log

  # ---------------------------------------------------------------------------
  # Mock Sabre Air clients
  # ---------------------------------------------------------------------------

  defmodule MockClientNoFlights do
    @behaviour Prodigy.Server.Service.Sabre.SabreAirClient
    def handle_request(_map), do: []
  end

  defmodule MockClientTwoFlights do
    @behaviour Prodigy.Server.Service.Sabre.SabreAirClient
    def handle_request(_map) do
      [
        %{
          flight: "AA 1261", origin: "JFK", depart: " 600P", dest: "LAX",
          arrive: "1103P", formatted_date: "OCT 01 91",
          stops: 0, equip: "D10", meal: "8",
          booking_classes: ["F", "Y", "B", "M", "H", "Q", "V", "K"]
        },
        %{
          flight: "UA  456", origin: "JFK", depart: " 900P", dest: "LAX",
          arrive: " 100A", formatted_date: "OCT 01 91",
          stops: 0, equip: "757", meal: "8",
          booking_classes: ["Y", "B", "M", "H", "Q"]
        }
      ]
    end
  end

  defmodule MockClientThreeFlights do
    @behaviour Prodigy.Server.Service.Sabre.SabreAirClient
    def handle_request(_map) do
      [
        %{
          flight: "AA 1261", origin: "JFK", depart: " 600P", dest: "LAX",
          arrive: "1103P", formatted_date: "OCT 01 91",
          stops: 0, equip: "D10", meal: "8",
          booking_classes: ["F", "Y", "B", "M", "H", "Q", "V", "K"]
        },
        %{
          flight: "UA  456", origin: "JFK", depart: " 900P", dest: "LAX",
          arrive: " 100A", formatted_date: "OCT 01 91",
          stops: 0, equip: "757", meal: "8",
          booking_classes: ["Y", "B", "M", "H", "Q"]
        },
        %{
          flight: "DL  789", origin: "JFK", depart: "1100P", dest: "LAX",
          arrive: " 300A", formatted_date: "OCT 01 91",
          stops: 0, equip: "767", meal: "8",
          booking_classes: ["Y", "M", "Q"]
        }
      ]
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Send an Eaasy Sabre payload through the router and return the ES response payload.
  defp send_es(router_pid, payload) do
    {:ok, response} =
      Router.handle_packet(router_pid, %Fm0{
        src: 0x0,
        dest: 0x063201,
        logon_seq: 0,
        message_id: 0,
        function: Fm0.Function.APPL_0,
        payload: payload
      })

    {:ok, %Fm0{payload: es_payload}} = DiaPacket.decode(response)
    es_payload
  end

  # Extract the page code from an ES response header: <<7, 0, 0x01, page::16-big, ...>>
  defp page_code(<<7, 0, 0x01, code::16-big, _rest::binary>>), do: code

  # Extract the field count from an ES response header.
  defp field_count(<<7, 0, 0x01, _code::16-big, count, 0, _rest::binary>>), do: count

  setup do
    prev_client = Application.get_env(:server, :sabre_air_client)
    Application.put_env(:server, :sabre_air_client, MockClientNoFlights)
    on_exit(fn -> Application.put_env(:server, :sabre_air_client, prev_client) end)
    {:ok, router_pid} = GenServer.start_link(Router, nil)
    [router_pid: router_pid]
  end

  # ===========================================================================
  # SabreAirMapper unit tests
  # ===========================================================================

  describe "SabreAirMapper.to_map/1" do
    test "parses origin, destination, and date" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,1")
      assert result.type == :airline
      assert result.departure == "JFK"
      assert result.arrival == "LAX"
      assert String.ends_with?(result.date, "-10-01")
    end

    test "parses departure time" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,1")
      assert result.time == "18:00:00"
      assert result.passengers == "1"
    end

    test "parses flight number into carrier and number" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,AA1261,2")
      assert result.carrier == "AA"
      assert result.flight_number == "1261"
      assert result.passengers == "2"
    end

    test "parses carrier code separate from time" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,DL,1")
      assert result.carrier == "DL"
      assert result.time == "18:00:00"
    end

    test "parses booking class" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,3,Q")
      assert result.booking_class == "Q"
      assert result.passengers == "3"
    end

    test "parses connection city" do
      result = SabreAirMapper.to_map("/AIR,JFK,LAX,OCT01,600P,DL,2,CHICAGO")
      assert result.connection_city == "CHICAGO"
    end
  end

  describe "SabreAirMapper.time_to_sabre/1" do
    test "converts noon" do
      assert SabreAirMapper.time_to_sabre(~T[12:00:00]) == "1200P"
    end

    test "converts midnight" do
      assert SabreAirMapper.time_to_sabre(~T[00:00:00]) == "1200A"
    end

    test "converts a PM time" do
      assert SabreAirMapper.time_to_sabre(~T[18:00:00]) == " 600P"
    end

    test "converts a four-digit AM time" do
      assert SabreAirMapper.time_to_sabre(~T[10:30:00]) == "1030A"
    end

    test "pads single-digit hours with a leading space" do
      assert SabreAirMapper.time_to_sabre(~T[01:15:00]) == " 115A"
    end
  end

  describe "SabreAirMapper type predicates" do
    test "is_flight_time accepts valid time strings" do
      assert SabreAirMapper.is_flight_time("600P")
      assert SabreAirMapper.is_flight_time("1030A")
      assert SabreAirMapper.is_flight_time("1259P")
    end

    test "is_flight_time rejects non-time strings" do
      refute SabreAirMapper.is_flight_time("AA444")
      refute SabreAirMapper.is_flight_time("1")
      refute SabreAirMapper.is_flight_time("CHICAGO")
    end

    test "is_flight_number accepts carrier+digits format" do
      assert SabreAirMapper.is_flight_number("AA444")
      assert SabreAirMapper.is_flight_number("DL1234")
      assert SabreAirMapper.is_flight_number("UA7777")
    end

    test "is_flight_number rejects bare carrier codes and times" do
      refute SabreAirMapper.is_flight_number("AA")
      refute SabreAirMapper.is_flight_number("600P")
    end

    test "is_carrier accepts two-character codes" do
      assert SabreAirMapper.is_carrier("AA")
      assert SabreAirMapper.is_carrier("DL")
      assert SabreAirMapper.is_carrier("U2")
    end

    test "is_carrier rejects codes of wrong length or case" do
      refute SabreAirMapper.is_carrier("AAA")
      refute SabreAirMapper.is_carrier("a")
      refute SabreAirMapper.is_carrier("aa")
    end

    test "is_passenger_count accepts single digits" do
      assert SabreAirMapper.is_passenger_count("1")
      assert SabreAirMapper.is_passenger_count("9")
    end

    test "is_passenger_count rejects multi-digit and non-digit strings" do
      refute SabreAirMapper.is_passenger_count("10")
      refute SabreAirMapper.is_passenger_count("A")
    end
  end

  describe "SabreAirMapper.mapper_date_format/1" do
    test "formats an ISO date string for terminal display" do
      assert SabreAirMapper.mapper_date_format("2026-10-01") == "Oct 01"
    end

    test "formats December correctly" do
      assert SabreAirMapper.mapper_date_format("2026-12-25") == "Dec 25"
    end
  end

  # ===========================================================================
  # Navigation tests
  # ===========================================================================

  test "SIGNON navigates to main menu", context do
    payload = send_es(context.router_pid, "/SIGNON")
    assert page_code(payload) == 0x4700
  end

  test "/M navigates to main menu", context do
    send_es(context.router_pid, "/SIGNON")
    payload = send_es(context.router_pid, "/M")
    assert page_code(payload) == 0x4700
  end

  test "/T navigates to main menu", context do
    send_es(context.router_pid, "/SIGNON")
    payload = send_es(context.router_pid, "/T")
    assert page_code(payload) == 0x4700
  end

  test "SIGNOFF returns empty response and resets state", context do
    send_es(context.router_pid, "/SIGNON")
    payload = send_es(context.router_pid, "/SIGNOFF")
    assert payload == <<0x0>>
  end

  test "/E exits and resets state", context do
    send_es(context.router_pid, "/SIGNON")
    payload = send_es(context.router_pid, "/E")
    assert payload == <<0x0>>
  end

  test "main menu selection 2 navigates to travel reservations", context do
    send_es(context.router_pid, "/SIGNON")
    payload = send_es(context.router_pid, "2")
    assert page_code(payload) == 0x0D03
  end

  test "travel reservations selection 1 navigates to flight input", context do
    send_es(context.router_pid, "/SIGNON")
    send_es(context.router_pid, "2")
    payload = send_es(context.router_pid, "1")
    assert page_code(payload) == 0x0200
  end

  test "unknown main menu selection returns no-op", context do
    send_es(context.router_pid, "/SIGNON")
    payload = send_es(context.router_pid, "9")
    assert payload == <<0>>
  end

  # ===========================================================================
  # Flight search tests
  # ===========================================================================

  test "/AIR with no results returns flight results page with only the date field", context do
    Application.put_env(:server, :sabre_air_client, MockClientNoFlights)
    payload = send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    assert page_code(payload) == 0x0900
    assert field_count(payload) == 1
  end

  test "/AIR with two results returns field count of 9 (1 date + 2×4)", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    payload = send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    assert page_code(payload) == 0x0900
    assert field_count(payload) == 9
  end

  test "/AIR with three results returns field count of 13 (1 date + 3×4)", context do
    Application.put_env(:server, :sabre_air_client, MockClientThreeFlights)
    payload = send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    assert page_code(payload) == 0x0900
    assert field_count(payload) == 13
  end

  # ===========================================================================
  # Flight selection tests
  # ===========================================================================

  test "selecting flight 1 navigates to booking class page", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    payload = send_es(context.router_pid, "1")
    assert page_code(payload) == 0x1B00
  end

  test "selecting flight 2 navigates to booking class page", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    payload = send_es(context.router_pid, "2")
    assert page_code(payload) == 0x1B00
  end

  test "selecting flight 3 navigates to booking class page", context do
    Application.put_env(:server, :sabre_air_client, MockClientThreeFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    payload = send_es(context.router_pid, "3")
    assert page_code(payload) == 0x1B00
  end

  test "selecting a flight number beyond the result count returns no-op", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    payload = send_es(context.router_pid, "5")
    assert payload == <<0>>
  end

  # ===========================================================================
  # Booking class selection tests
  # ===========================================================================

  test "selecting a valid booking class navigates to travel profile page", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    send_es(context.router_pid, "1")
    payload = send_es(context.router_pid, "1")
    assert page_code(payload) == 0x2C01
  end

  test "selecting a booking class index beyond available classes returns no-op", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    send_es(context.router_pid, "1")
    # Flight 1 has 8 booking classes (F Y B M H Q V K); 9 is out of range
    payload = send_es(context.router_pid, "9")
    assert payload == <<0>>
  end

  # ===========================================================================
  # Travel profile and reservations made tests
  # ===========================================================================

  test "travel profile selection 1 navigates to reservations made", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    send_es(context.router_pid, "1")  # select flight 1
    send_es(context.router_pid, "1")  # select booking class 1
    payload = send_es(context.router_pid, "1")  # travel profile 1
    assert page_code(payload) == 0x2300
  end

  test "second flight booking skips travel profile and goes directly to reservations made", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    # Book the outbound flight
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    send_es(context.router_pid, "1")   # select flight 1
    send_es(context.router_pid, "1")   # select booking class 1
    send_es(context.router_pid, "1")   # travel profile (sets profile_selected: true)
    # Navigate to return flight
    send_es(context.router_pid, "4")   # continue/complete
    send_es(context.router_pid, "1")   # add return flight
    send_es(context.router_pid, "OCT15")  # enter return date -> flight results
    send_es(context.router_pid, "1")   # select return flight 1
    # Booking class selection should skip travel profile since it was already shown
    payload = send_es(context.router_pid, "1")
    assert page_code(payload) == 0x2300
  end

  test "reservations made selection 4 advances to continue/complete page", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "1")
    payload = send_es(context.router_pid, "4")
    assert page_code(payload) == 0x2500
  end

  test "reservations made selection 5 cancels and returns to travel reservations", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "1")
    payload = send_es(context.router_pid, "5")
    assert page_code(payload) == 0x0D03
  end

  # ===========================================================================
  # Return flight tests
  # ===========================================================================

  test "continue/complete selection 1 navigates to return flight date page", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "4")
    payload = send_es(context.router_pid, "1")
    assert page_code(payload) == 0xB903
  end

  test "entering return flight date searches and returns flight results page", context do
    Application.put_env(:server, :sabre_air_client, MockClientTwoFlights)
    send_es(context.router_pid, "/AIR,JFK,LAX,OCT01,600P,1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "1")
    send_es(context.router_pid, "4")
    send_es(context.router_pid, "1")    # add return flight -> return flight date
    payload = send_es(context.router_pid, "OCT15")
    assert page_code(payload) == 0x0900
  end
end
