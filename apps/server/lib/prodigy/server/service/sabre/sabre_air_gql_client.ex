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

defmodule Prodigy.Server.Service.Sabre.SabreAirGqlClient do
  @moduledoc """
  GraphQL client implementation for Sabre Air requests.

  This module implements the `Prodigy.Server.Service.Sabre.SabreAirClient` behaviour,
  handling flight queries by sending GraphQL requests to a configured endpoint and
  parsing the responses.

  ## Configuration

  The GraphQL endpoint URL can be configured via:

      config :server, :sabre_graphql_url, "http://your-api-endpoint/api/graphql"

  If not configured, defaults to `http://localhost:4000/api/graphql`.
  """

  alias Prodigy.Server.Service.EaasySabre
  alias Prodigy.Server.Service.Sabre.SabreAirMapper

  require Logger

  @url "http://localhost:4004/api/graphql"

  @behaviour Prodigy.Server.Service.Sabre.SabreAirClient

  @doc """
  Handles a Sabre Air request by querying the GraphQL flight API.

  Builds a GraphQL query from the request map, sends it to the configured
  endpoint, and parses the response into a list of flight maps.
  """
  def handle_request(sabre_map) do
    # Implementation of request handling

    # A string will be posted to the GraphQL endpoint and a response received
    post_body = build_request(sabre_map)

    Logger.info("Sending GraphQL request: #{post_body}")
    url = Application.get_env(:server, :sabre_graphql_url, @url)

    response =
      Req.post(url,
        body: post_body,
        headers: %{"Content-Type" => "text/plain"}
      )

    Logger.info("Received GraphQL response: #{inspect(response)}")
    parse_response(response)
  end

  defp parse_response(response) do
    # Parse the GraphQL response body and extract flight information
    case response do
      {:ok, %Req.Response{status: 200, body: body}} ->
        try do
          body |> Map.get("data") |> Map.get("flights") |> es_map()
        rescue
          e ->
            IO.puts("Failed to parse GraphQL response body: #{inspect(e)}")
            []
        end

      {:ok, %Req.Response{status: status}} ->
        IO.puts("GraphQL request failed with status: #{status}")
        []

      {:error, reason} ->
        IO.puts("GraphQL request error: #{inspect(reason)}")
        []
    end
  end

  defp build_request(sabre_map) do
    # Build the GraphQL request body from the sabre_map

    fromDate_text = "fromDate: \"#{adjust_date(sabre_map.date)}\", "
    toDate_text = "toDate: \"#{adjust_date(sabre_map.date)}\", "
    origin_text = "origin: \"#{sabre_map.departure}\", "
    dest_text = "dest: \"#{sabre_map.arrival}\", "

    carrier_text =
      if Map.has_key?(sabre_map, :carrier) and sabre_map.carrier != nil do
        "carrier: \"#{sabre_map.carrier}\", "
      else
        ""
      end

    # If there's a flight number, use it directly else there should be a departure time to use
    f_or_d_text =
      cond do
        Map.has_key?(sabre_map, :flight_number) and sabre_map.flight_number != nil ->
          "flightNumber: \"#{sabre_map.flight_number}\", "

        Map.has_key?(sabre_map, :time) and sabre_map.time != nil ->
          "departureTime: \"#{sabre_map.time}\", "

        true ->
          ""
      end

    """
    query {
      flights(
        #{fromDate_text}
        #{toDate_text}
        #{origin_text}
        #{dest_text}
        #{carrier_text}
        #{f_or_d_text}
        limit: #{EaasySabre.max_flights()}) {
          id
          flightNumber
          date
          origin
          dest
          carrier
          arrivalTime
          departureTime
          airline {
            name
          }
      }
    }
    """
  end

  defp adjust_date(date_text) do
    date = Date.from_iso8601!(date_text)
    year_shift = 2013 - date.year
    Date.shift(date, year: year_shift) |> Date.to_string()
  end

  # Converts a list of flight maps from the GraphQL response into the format expected by eaasy_sabre module.
  defp es_map(flights) when is_list(flights) do
    Enum.map(flights, fn flight ->
      es_one_flight_map(flight)
    end)
    |> Enum.with_index()
    |> Enum.map(fn {flight, idx} -> Map.put(flight, :index, idx) end)
  end

  defp es_one_flight_map(flight) do
    departure_text = Time.from_iso8601!(Map.get(flight, "departureTime")) |> SabreAirMapper.time_to_sabre()
    arrival_text = Time.from_iso8601!(Map.get(flight, "arrivalTime")) |> SabreAirMapper.time_to_sabre()
    padded_flight_number = String.pad_leading(Map.get(flight, "flightNumber"), 4, " ")

    header_date = Date.from_iso8601!(Map.get(flight, "date"))
    formatted_date = Calendar.strftime(header_date, "%3b %02d %02y") |> String.upcase()

    %{
      flight: flight["carrier"] <> " " <> padded_flight_number,
      origin: flight["origin"],
      depart: departure_text,
      dest: flight["dest"],
      arrive: arrival_text,
      formatted_date: formatted_date,
      # Dummy values for required fields not provided by GraphQL API
      stops: 0,
      equip: "D10",
      meal: "8",
      booking_classes: ["F", "Y", "B", "M", "H", "Q", "V", "K"]
    }
  end
end
