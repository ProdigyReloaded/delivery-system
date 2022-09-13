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

defmodule Prodigy.Server.Service.Logoff.Test do
  @moduledoc false
  use Prodigy.Server.RepoCase

  import Mock

  require Mix
  require Logger

  alias Prodigy.Core.Data.User
  alias Prodigy.Server.Session
  alias Prodigy.Server.Service.Logoff
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0

  @moduletag :capture_log

  #  doctest Logon

  defp epoch() do
    {:ok, result} = DateTime.from_unix(0)
    result
  end

  @test_user_id1 "AAAA12D"
  @test_user_id2 "AAAA12E"

  setup_with_mocks([
    {Calendar.DateTime, [], [now_utc: fn -> epoch() end]}
  ]) do
    :ok
  end

  # TODO make these packets go through the router for best coverage

  def make_logoff_request(_user) do
    %Fm0{src: 0x0, dest: 0xD201, logon_seq: 0, message_id: 0, function: Fm0.Function.APPL_0}
  end

  test "success and not inuse" do
    # create fixtures
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    Repo.insert!(%User{
      id: @test_user_id1,
      password: "test",
      gender: "M",
      date_enrolled: today,
      logged_on: true
    })

    user =
      User
      |> Ecto.Query.where([u], u.id == @test_user_id1)
      |> Ecto.Query.first()
      |> Repo.one()

    assert user.logged_on == true

    request = make_logoff_request(@test_user_id1)
    {:disconnect, %Session{}, _response} = Logoff.handle(request, %Session{user: user})

    user =
      User
      |> Ecto.Query.where([u], u.id == @test_user_id1)
      |> Ecto.Query.first()
      |> Repo.one()

    assert user.logged_on == false
  end

  test "abnormal and not inuse" do
    # create fixtures
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    Repo.insert!(%User{
      id: @test_user_id2,
      password: "test",
      gender: "M",
      date_enrolled: today,
      logged_on: true
    })

    user =
      User
      |> Ecto.Query.where([u], u.id == @test_user_id2)
      |> Ecto.Query.first()
      |> Repo.one()

    assert user.logged_on == true

    :ok = Logoff.handle_abnormal(user)

    user =
      User
      |> Ecto.Query.where([u], u.id == @test_user_id2)
      |> Ecto.Query.first()
      |> Repo.one()

    assert user.logged_on == false
  end
end
