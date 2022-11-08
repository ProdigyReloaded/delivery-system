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

defmodule Prodigy.Server.Service.Tocs.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase

  require Mix
  require Ecto.Query
  require Logger

  alias Prodigy.Core.Data.Object
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm64}
  alias Prodigy.Server.Router

  defp get_object(pid, object_id, seq, type, version \\ nil) do
    payload =
      if version == nil do
        <<object_id::binary-size(11), seq, type>>
      else
        <<object_id::binary-size(11), seq, type, version::16-little>>
      end

    random_id = Enum.random(0..255)

    response =
      Router.handle_packet(pid, %Fm0{
        src: 0x0,
        dest: 0x0200,
        logon_seq: 0,
        message_id: random_id,
        function: Fm0.Function.APPL_0,
        payload: payload
      })

    {random_id, response}
  end

  setup do
    {:ok, router_pid} = GenServer.start_link(Router, nil)

    Repo.insert!(%Object{
      name: "ITRC0001D  ",
      sequence: 0x1,
      type: 0xC,
      version: 0x123,
      contents: <<"foobar">>
    })

    [router_pid: router_pid]
  end

  test "RS has most recent version of requested object", context do
    {random_id, {:ok, response}} = get_object(context.router_pid, "ITRC0001D  ", 0x1, 0xC, 0x1234)
    <<0x0, ^random_id, 0, 0, 0::16-big>> = response
  end

  test "RS doesn't have object", context do
    {random_id, {:ok, response}} = get_object(context.router_pid, "ITRC0001D  ", 0x1, 0xC, 0x0)
    <<0x0, ^random_id, 0, 0, 6::16-big, "foobar"::binary>> = response
  end

  test "RS doesn't have object (no version bytes sent)", context do
    {random_id, {:ok, response}} = get_object(context.router_pid, "ITRC0001D  ", 0x1, 0xC)
    <<0x0, ^random_id, 0, 0, 6::16-big, "foobar"::binary>> = response
  end

  test "RS object version is older than TOCS", context do
    {random_id, {:ok, response}} = get_object(context.router_pid, "ITRC0001D  ", 0x1, 0x0C, 0x22)
    <<0x0, ^random_id, 0, 0, 6::16-big, "foobar"::binary>> = response
  end

  test "RS has object and TOCS doesn't", context do
    {random_id, {:ok, response}} = get_object(context.router_pid, "TLOT0011PG ", 0x1, 0x4, 0x1)
    <<0x0, ^random_id, 0, 0, 0::16-big>> = response
  end

  test "RS does not have object and neither does TOCS", context do
    {random_id, {:ok, response}} = get_object(context.router_pid, "TQ000044BDY", 0x0, 0x8, 0x0)
    {:ok, response} = DiaPacket.decode(response)

    assert response.concatenated == true
    assert response.dest == 0x0
    assert response.src == 0x0200
    assert response.function == Fm0.Function.APPL_0
    assert response.logon_seq == 0
    assert response.message_id == random_id
    assert response.mode.response == true
    assert response.mode.response_expected == false
    assert response.fm64.data_mode == Fm64.DataMode.BINARY
    assert response.fm64.status_type == Fm64.StatusType.ERROR
    assert response.fm64.payload == <<0xC>>
  end

  test "RS gets latest available version from TOCS", context do
    Repo.insert!(%Object{
      name: "FM00000APG ",
      sequence: 0x0,
      type: 0x4,
      version: 0x123,
      contents: <<"foobar">>
    })

    {random_id, {:ok, response}} = get_object(context.router_pid, "FM00000APG ", 0x0, 0x4, 0x22)
    <<0x0, ^random_id, 0, 0, 6::16-big, "foobar"::binary>> = response

    Repo.insert!(%Object{
      name: "FM00000APG ",
      sequence: 0x0,
      type: 0x4,
      version: 0x200,
      contents: <<"bazqux">>
    })

    {random_id, {:ok, response}} = get_object(context.router_pid, "FM00000APG ", 0x0, 0x4, 0x22)
    <<0x0, ^random_id, 0, 0, 6::16-big, "bazqux"::binary>> = response
  end
end
