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
  alias Prodigy.Server.Session
  alias Prodigy.Server.Service.Tocs
  alias Prodigy.Server.Protocol.Dia.Packet.{Fm0, Fm64}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket

  # TODO make these packets go through the router for best coverage

  defp make_tocs_request(object_id, seq, type, version) do
    # TODO should we right pad the object id?
    random_id = Enum.random(0..255)

    {random_id,
     %Fm0{
       src: 0x0,
       dest: 0x0200,
       logon_seq: 0,
       message_id: random_id,
       function: Fm0.Function.APPL_0,
       payload: <<object_id::binary-size(11), seq, type, version::16-little>>
     }}
  end

  defp make_tocs_request(object_id, seq, type) do
    # TODO should we right pad the object id?
    random_id = Enum.random(0..255)

    {random_id,
     %Fm0{
       src: 0x0,
       dest: 0x0200,
       logon_seq: 0,
       message_id: random_id,
       function: Fm0.Function.APPL_0,
       payload: <<object_id::binary-size(11), seq, type>>
     }}
  end

  defp make_fixture() do
    Repo.insert!(%Object{
      name: "ITRC0001D  ",
      sequence: 0x1,
      type: 0xC,
      version: 0x123,
      contents: <<"foobar">>
    })
  end

  test "RS has most recent version of requested object" do
    make_fixture()

    {random_id, request} = make_tocs_request("ITRC0001D  ", 0x1, 0xC, 0x1234)
    {:ok, %Session{}, <<0x0, ^random_id, 0, 0, 0::16-big>>} = Tocs.handle(request)
  end

  test "RS doesn't have object" do
    make_fixture()

    {random_id, request} = make_tocs_request("ITRC0001D  ", 0x1, 0xC, 0x0)

    {:ok, %Session{}, <<0x0, ^random_id, 0, 0, 6::16-big, "foobar"::binary>>} =
      Tocs.handle(request)
  end

  test "RS doesn't have object (no version bytes sent)" do
    make_fixture()

    {random_id, request} = make_tocs_request("ITRC0001D  ", 0x1, 0xC)

    {:ok, %Session{}, <<0x0, ^random_id, 0, 0, 6::16-big, "foobar"::binary>>} =
      Tocs.handle(request)
  end

  test "RS object version is older than TOCS" do
    make_fixture()

    {random_id, request} = make_tocs_request("ITRC0001D  ", 0x1, 0x0C, 0x22)
    Logger.debug("#{inspect(request, base: :hex, limit: :infinity)}")

    {:ok, %Session{}, <<0x0, ^random_id, 0, 0, 6::16-big, "foobar"::binary>>} =
      Tocs.handle(request)
  end

  test "RS has object and TOCS doesn't" do
    make_fixture()

    {random_id, request} = make_tocs_request("TLOT0011PG ", 0x1, 0x4, 0x1)
    {:ok, %Session{}, <<0x0, ^random_id, 0, 0, 0::16-big>>} = Tocs.handle(request)
  end

  test "RS does not have object and neither does TOCS" do
    make_fixture()

    {random_id, request} = make_tocs_request("TQ000044BDY", 0x0, 0x8, 0x0)
    {:ok, %Session{}, response_packet} = Tocs.handle(request)
    {:ok, response} = DiaPacket.decode(response_packet)

    assert response.concatenated == true
    assert response.dest == request.src
    assert response.src == request.dest
    assert response.function == Fm0.Function.APPL_0
    assert response.logon_seq == 0
    assert response.message_id == random_id
    assert response.mode.response == true
    assert response.mode.response_expected == false
    assert response.fm64.data_mode == Fm64.DataMode.BINARY
    assert response.fm64.status_type == Fm64.StatusType.ERROR
    assert response.fm64.payload == <<0xC>>
  end

  test "RS gets latest available version from TOCS" do
    Repo.insert!(%Object{
      name: "FM00000APG ",
      sequence: 0x0,
      type: 0x4,
      version: 0x123,
      contents: <<"foobar">>
    })

    {random_id, request} = make_tocs_request("FM00000APG ", 0x0, 0x4, 0x22)

    {:ok, %Session{}, <<0x0, ^random_id, 0, 0, 6::16-big, "foobar"::binary>>} =
      Tocs.handle(request)

    Repo.insert!(%Object{
      name: "FM00000APG ",
      sequence: 0x0,
      type: 0x4,
      version: 0x200,
      contents: <<"bazqux">>
    })

    {random_id, request} = make_tocs_request("FM00000APG ", 0x0, 0x4, 0x22)

    {:ok, %Session{}, <<0x0, ^random_id, 0, 0, 6::16-big, "bazqux"::binary>>} =
      Tocs.handle(request)
  end
end
