# Copyright 2026, Phillip Heller
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

defmodule Prodigy.Server.Service.LogonMemberStatus.Test do
  @moduledoc """
  Logon honors the TOOLS Add/Suspend member state. A household member whose
  ACTIVE bit is clear in the household-level PRF_INDICATORS_<suffix> byte has
  been suspended and is refused with ACCOUNT_PROBLEM; an active member logs on
  normally. (A missing indicator - a legacy household - reads as active and is
  covered by logon_logoff_test's SUCCESS cases.)
  """
  use Prodigy.Server.RepoCase
  import Server
  import Ecto.Changeset
  import Mock

  alias Prodigy.Core.Data.Service.{Household, MemberStatus, User}
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Router
  alias Prodigy.Server.Service.Logon.Status

  @moduletag :capture_log

  defp epoch do
    {:ok, result} = DateTime.from_unix(0)
    result
  end

  setup_with_mocks([
    {Calendar.DateTime, [], [now_utc: fn -> epoch() end]}
  ]) do
    {:ok, router_pid} = GenServer.start_link(Router, nil)
    [router_pid: router_pid]
  end

  @today DateTime.to_date(DateTime.utc_now())

  # Enrolled slot-A subscriber in household AAAA12, whose household profile
  # carries the given PRF_INDICATORS_A byte.
  defp insert_household(indicator_profile) do
    %Household{id: "AAAA12", enabled_date: @today, profile: indicator_profile}
    |> change
    |> put_assoc(:users, [
      %User{id: "AAAA12A", profile: %{"0157" => "F"}, date_enrolled: @today}
      |> User.changeset(%{password: "foobaz"})
    ])
    |> Repo.insert!()
  end

  defp logon_status(pid) do
    {:ok, response} = logon(pid, "AAAA12A", "foobaz", "06.03.10")
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    status
  end

  test "a suspended member (active bit clear) is refused at logon", context do
    insert_household(MemberStatus.put_indicators(%{}, "A", false, true))

    assert logon_status(context.router_pid) == Status.ACCOUNT_PROBLEM.value()

    ensure_logoff(context.router_pid)
  end

  test "an active member (active bit set) logs on normally", context do
    insert_household(MemberStatus.put_indicators(%{}, "A", true, true))

    assert logon_status(context.router_pid) == Status.SUCCESS.value()

    ensure_logoff(context.router_pid)
  end
end
