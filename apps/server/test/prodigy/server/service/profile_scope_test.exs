defmodule Prodigy.Server.Service.ProfileScopeTest do
  @moduledoc """
  Scope enforcement for profile writes (Fm0 action 0x04): a non-subscriber
  member must not be able to update household / subscriber-only GEVs (the
  ADDRESS & MEMBER INFO / option-5 section). These cases exercise the
  Repo-free rejection path, so no database fixtures are needed - the write is
  refused before any changeset is built.
  """
  use ExUnit.Case, async: true

  alias Prodigy.Core.Data.Service.{Household, User}
  alias Prodigy.Server.Context
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Service.Profile

  # Build a single-entry 0x04 profile-write packet for user_id writing tac=value.
  defp write_packet(user_id, tac, value) do
    entry = <<tac::16-big, byte_size(value), value::binary>>

    payload =
      <<0x13, 0x04, 0x1, user_id::binary-size(7), 0::40, 1::16-big, entry::binary>>

    %Fm0{
      src: 0x0,
      dest: 0x2201,
      logon_seq: 0,
      message_id: 0,
      function: Fm0.Function.APPL_0,
      payload: payload
    }
  end

  defp handle_status(user, packet) do
    {:ok, _ctx, response} = Profile.handle(packet, %Context{user: user})
    {:ok, %Fm0{payload: <<status, _rest::binary>>}} = DiaPacket.decode(response)
    status
  end

  # A non-A member; household present but empty so nothing is resident.
  defp member(id), do: %User{id: id, household: %Household{id: String.slice(id, 0, 6), profile: %{}}}

  test "member write to the household password (0x0113) is rejected" do
    # 0x0113 is update: [:subscriber]; a B member is :user -> reject (status != 0x30/'0').
    assert handle_status(member("AAAA14B"), write_packet("AAAA14B", 0x0113, "SECRET")) == 0x05
  end

  test "member write to a household billing-address GEV (0x0102) is rejected" do
    assert handle_status(member("AAAA14C"), write_packet("AAAA14C", 0x0102, "1 MAIN ST")) == 0x05
  end

  test "member write to their OWN password (0x014F, :user scope) is not scope-denied" do
    # 0x014F is update: [:user]; the scope check must let it through. It then
    # proceeds to the changeset path (which needs a DB), so we only assert it
    # is NOT the scope-denied refusal - any other outcome (including a DB error
    # from the missing row) proves the scope gate did not block it.
    result =
      try do
        handle_status(member("AAAA14D"), write_packet("AAAA14D", 0x014F, "MINE12"))
      rescue
        _ -> :proceeded_past_scope_gate
      end

    refute result == 0x05
  end
end
