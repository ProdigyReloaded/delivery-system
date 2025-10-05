# Copyright 2022-2025, Phillip Heller
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

defmodule Prodigy.Server.Router do
  @moduledoc """
  The Router implements the service invocation function and stores context data.

  An instance of the Router is created for each active connection.

  The Router is responsible for:
  * Storing an instance of `Prodigy.Server.Context`
  * receiving packets from `Prodigy.Server.Protocol.Dia`
  * invoking the appropriate Service (that implements `Prodigy.Server.Service`) and passing to it the packet itself and
    the context
  * Storing the updated Context as received from the Service
  * Returning any response received from the service to the reception system (note, DIA vs TOCS)
  """

  require Logger
  use GenServer
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context

  alias Prodigy.Server.Service.{
    AddressBook,
    Ads,
    BulletinBoards,
    Cmc,
    DataCollection,
    DowJones,
    Enrollment,
    Logoff,
    Logon,
    Messaging,
    Profile,
    Tocs
  }

  defmodule State do
    defstruct context: %Context{}
  end

  def handle_packet(pid, %Fm0{} = packet), do: GenServer.call(pid, {:handle_packet, packet})

  @impl GenServer
  def init(_) do
    Logger.debug("router started")
    Process.flag(:trap_exit, true)
    {:ok, %State{context: %Context{auth_timeout: Context.set_auth_timer()}}}
  end

  defmodule Default do
    @moduledoc "A default implementation of Prodigy.Server.Service to handle packets to unknown destinations"
    @behaviour Prodigy.Server.Service

    def handle(%Fm0{dest: dest} = packet, state) do
      Logger.error("FM0 packet to unknown destination #{inspect(dest, base: :hex)}")
      Logger.debug("#{inspect(packet, base: :hex, limit: :infinity)}")
      {:ok, state, <<>>}
    end
  end

  @doc """
  Dispatch packets to the relevant service module.

  The service module is selected by the following:
  * DIA destination ID
  * When necessary, the first byte of the DIA packet payload

  The entire deserialized DIA Fm0 packet (`Prodigy.Server.Protocol.Dia.Packet.Fm0`) and the `Prodigy.Server.Context` is
  passed to the service.  The service returns:
  * A status atom (:ok, :error, or :disconnect)
  * The `Prodigy.Server.Context` struct, updated as appropriate
  * Optionally, A binary response payload

  The router will update the stored `Prodigy.Server.Context` with the value returned, and the binary response payload
  will be returned to `Prodigy.Server.Protocol.Dia`, then to `Prodigy.Server.Protocol.Tcs` where it will ultimately be
  chunked, encapsulated, and sent to the Reception System.
  """
  # credo:disable-for-lines:2 Credo.Check.Refactor.CyclomaticComplexity
  @impl GenServer
  def handle_call({:handle_packet, %Fm0{dest: dest, payload: payload} = packet}, _from, state) do
    service =
      case dest do
        0x000200 ->
          Tocs

        0x002200 ->
          Logon

        0x002201 ->
          Enrollment

        0x00D200 ->
          case payload do
            <<0x01, _rest::binary>> -> Messaging
            <<0x02, _rest::binary>> -> Ads
            <<0x03, _rest::binary>> -> BulletinBoards
            <<0x04, _rest::binary>> -> DataCollection
            # sends 0xF on entry and exit; Mailing List sends 06
            <<0x0D, _rest::binary>> -> AddressBook
          end

        0x00D201 ->
          Logoff

        # This is for subsequent logons, so no disconnect, but set the auth_timeout
        0x00D202 ->
          Logoff

        0x00D203 ->
          Profile

        0x020200 ->
          Cmc

        # 0x040210 -> QuoteTrack # get this when trying to go into quote track 1 or 2 on dow jones
        # 0x060201 -> Banking
        # 0x063201 -> EaasySabre
        0x067201 ->
          DowJones

        # this is the made up destination for the dow jones symbol to name resolve function
        0x009900 ->
          DowJones

        _ ->
          Default
      end

    case service.handle(packet, state.context) do
      {:ok, %Context{} = context} ->
        {:reply, {:ok}, %{state | context: context}}

      {:ok, %Context{} = context, response} ->
        {:reply, {:ok, response}, %{state | context: context}}

      {:error, %Context{} = context, response} ->
        {:reply, {:ok, response}, %{state | context: context}}

      # but want to exit at the end of this
      {:disconnect, %Context{}, response} ->
        {:reply, {:ok, response}, %Context{}}
    end
  end

  @impl GenServer
  def terminate(reason, %{context: %Context{user: user}} = _state) do
    # If the router is terminated with a connection still active, log the user off
    Logoff.handle_abnormal(user)
    Logger.debug("Router shutting down: #{inspect(reason)}")
    :normal
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("router state: #{inspect(state)}")
    Logger.debug("Router shutting down: #{inspect(reason)}")
    :normal
  end

  @impl true
  def handle_info(:auth_timeout, %{context: %Context{user: nil}} = state) do
    Logger.warning("authentication timeout")
    {:stop, :normal, state}
  end

  def handle_info(:auth_timeout, %{context: %Context{user: _user}} = state) do
    # User is logged in, ignore timeout
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end
end
