# Copyright 2022, Phillip Heller
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

defmodule Prodigy.Server.Service.DowJones do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Dow Jones requests
  """

  require Logger

  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm64}
  alias Prodigy.Server.Session

  defmodule YahooFinanceData do
    @moduledoc false
    defstruct quoteResponse: nil
  end

  defmodule Response do
    @moduledoc false
    defstruct result: []
  end

  defmodule Quote do
    @moduledoc false
    defstruct shortName: nil,
              regularMarketChange: nil,
              regularMarketDayHigh: nil,
              regularMarketDayLow: nil,
              regularMarketOpen: nil,
              regularMarketPrice: nil,
              regularMarketVolume: nil
  end

  defp decode_quote(symbol) do
    json =
      try do
        case Task.async(fn -> get_quote(symbol) end)
             |> Task.yield(3000) do
          nil -> raise RuntimeError, message: "Timeout"
          {:exit, _reason} -> raise RuntimeError, message: "Timeout"
          {:ok, {:ok, {_symbol, json}}} -> json
        end
      catch
        :exit, _reason -> raise RuntimeError, message: "Timeout"
      end

    yahoo_data =
      Poison.decode!(json, as: %YahooFinanceData{quoteResponse: %Response{result: [%Quote{}]}})

    Enum.at(yahoo_data.quoteResponse.result, 0)
  end

  defp get_quote(symbol) do
    YahooFinance.custom_quote(String.trim(symbol), [
      :longName,
      :shortName,
      :regularMarketChange,
      :regularMarketOpen,
      :regularMarketDayHigh,
      :regularMarketDayLow,
      :regularMarketPrice,
      :regularMarketVolume
    ])
  end

  @doc """
  This method handles Stock Symbol to Company Name resolution requests from the newly created logic in BNB00037.PGM.
  """
  def handle(%Fm0{dest: 0x009900, payload: symbol} = request, %Session{} = session) do
    Logger.debug("dow jones resolve symbol '#{symbol}' to short name")

    shortName =
      case(:ets.lookup(:dow_jones, symbol)) do
        [{_key, value}] ->
          value

        _ ->
          quote = decode_quote(symbol)
          Logger.info("Symbol #{symbol} not found in table, adding.")
          :ets.insert_new(:dow_jones, {symbol, quote.shortName})
          quote.shortName
      end

    Logger.debug("short name is #{shortName}")

    response = %{
      request
      | concatenated: false,
        src: request.dest,
        dest: request.src,
        mode: %Fm0.Mode{response: true},
        fm4: nil,
        fm9: nil,
        fm64: nil,
        payload: shortName
    }

    {:ok, session, DiaPacket.encode(response)}
  end

  def handle(
        %Fm0{dest: _dest, payload: <<0x2C, symbol::binary-size(5), 0xD>>} = request,
        %Session{user: _user} = session
      ) do
    Logger.debug("dow jones request #{inspect(request, base: :hex, limit: :infinity)}")

    response =
      try do
        quote = decode_quote(symbol)
        :ets.insert_new(:dow_jones, {symbol, quote.shortName})

        data =
          List.to_string(
            :io_lib.format(
              "~-10.2f~-10.2f~-10.2f~-10.2f~-10.2f~-10.s",
              [
                quote.regularMarketChange,
                quote.regularMarketOpen,
                quote.regularMarketDayHigh,
                quote.regularMarketDayLow,
                quote.regularMarketPrice,
                Number.Delimit.number_to_delimited(quote.regularMarketVolume)
              ]
            )
          )

        %{
          request
          | concatenated: true,
            src: request.dest,
            dest: request.src,
            mode: %Fm0.Mode{response: true},
            payload: <<0x3D, 0x04, 0x0>> <> data
        }
      rescue
        # TODO shouldn't be this broad in catching errors
        _ ->
          # ok, sending statustype INFORMATION or ERROR shows XXME47F4D\x01\x0c to the client
          fm64 = %Fm64{
            concatenated: false,
            status_type: Fm64.StatusType.ERROR,
            data_mode: Fm64.DataMode.BINARY,
            # action, message 41 - timeout
            payload: <<"A", "DJI00001", 0x1::16-big>>
          }

          # payload: << "W", "DJI00001", 0x0::16-big >>} # wait, message 0 - supposed to be "maximum resources in use"
          %{
            request
            | concatenated: true,
              src: request.dest,
              dest: request.src,
              mode: %Fm0.Mode{response: true},
              fm4: nil,
              fm64: fm64,
              payload: <<>>
          }
      end

    {:ok, session, DiaPacket.encode(response)}
  end
end
