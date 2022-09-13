# Copyright 2022, Phillip Heller
#
# This file is part of prodigyd.
#
# prodigyd is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# prodigyd is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License along with prodigyd. If not,
# see <https://www.gnu.org/licenses/>.

defmodule Prodigy.Server.Router do
  @moduledoc false

  require Logger
  use GenServer
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Session

  alias Prodigy.Server.Service.{
    Logon,
    Logoff,
    Profile,
    Tocs,
    Ads,
    Enrollment,
    Cmc,
    Messaging,
    AddressBook,
    DowJones,
    DataCollection
  }

  defmodule State do
    defstruct session: %Session{}
  end

  def handle_packet(pid, %Fm0{} = packet), do: GenServer.call(pid, {:handle_packet, packet})

  @impl GenServer
  def init(_) do
    Logger.debug("router started")
    Process.flag(:trap_exit, true)
    {:ok, %State{}}
  end

  defmodule Default do
    @behaviour Prodigy.Server.Service

    def handle(%Fm0{dest: dest} = packet, state) do
      Logger.error("FM0 packet to unknown destination #{inspect(dest, base: :hex)}")
      Logger.debug("#{inspect(packet, base: :hex, limit: :infinity)}")
      {:ok, state, <<>>}
    end
  end

  # TODO apps like TOCS, etc.  need to return errors or just force a disconnect if they are called without an active session
  # TODO refactor handle so that it returns the same thing from every application

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
            <<0x04, _rest::binary>> -> DataCollection
            # sends 0xF on entry and exit; Mailing List sends 06
            <<0x0D, _rest::binary>> -> AddressBook
          end

        0x00D201 ->
          Logoff

        # This is for subsequent logons, so no disconnect
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

        _ ->
          Default
      end

    case service.handle(packet, state.session) do
      {:ok, %Session{} = session} ->
        {:reply, {:ok}, %{state | session: session}}

      {:ok, %Session{} = session, response} ->
        {:reply, {:ok, response}, %{state | session: session}}

      {:error, %Session{} = session, response} ->
        {:reply, {:ok, response}, %{state | session: session}}

      # but want to exit at the end of this
      {:disconnect, %Session{}, response} ->
        {:reply, {:ok, response}, %Session{}}
    end
  end

  @impl GenServer
  def terminate(reason, %{session: %Session{user: user}} = _state) do
    # If the router is terminated with a session still active, log the user off
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
end
