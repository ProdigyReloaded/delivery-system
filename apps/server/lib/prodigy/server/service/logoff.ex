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

defmodule Prodigy.Server.Service.Logoff do
  @moduledoc """
  Handle Logoff requests
  """

  @behaviour Prodigy.Server.Service

  require Logger
  require Ecto.Query
  use EnumType

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Prodigy.Core.Data.{Repo, User}
  alias Prodigy.Server.Protocol.Dia.Packet
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Context
  alias Prodigy.Server.SessionManager

  @normal_logoff_dest 0x00D202
  @disconnect_logoff_dest 0x00D201

  defenum Status do
    @moduledoc "An enumeration of Logoff service responses"

    value SUCCESS, 0x0
  end

  @doc """
  Handles incoming logoff requests
  """
  def handle(%Fm0{} = request, %Context{user: nil}) do
    # No user in context - just send empty response
    response = build_empty_response(request)
    {:ok, %Context{}, response}
  end

  def handle(%Fm0{} = request, %Context{user: user} = context) do
    request
    |> parse_request(user)
    |> and_then(&update_last_logon_time/1)
    |> and_then(&end_session/1)
    |> and_then(&determine_result/1)
    |> and_then(&build_response/1)
    |> finalize_response(context)
  end

  @doc """
  Handles abnormal disconnection (e.g., connection drop)
  """
  def handle_abnormal(nil), do: :ok

  def handle_abnormal(user) do
    {:ok, %{user: user, reason: :abnormal, request: nil}}
    |> update_last_logon_time()
    |> and_then(&end_session/1)

    :ok
  end

  # Railway-oriented combinator - handles any :ok tuple
  defp and_then({:error, _} = error, _func), do: error
  defp and_then(success_tuple, func) when elem(success_tuple, 0) == :ok, do: func.(success_tuple)

  # Pipeline functions

  defp parse_request(request, user) do
    reason = case request.dest do
      @disconnect_logoff_dest -> :disconnect
      @normal_logoff_dest -> :normal
      _ -> :normal
    end

    {:ok, %{user: user, reason: reason, request: request}}
  end

  defp update_last_logon_time({:ok, %{user: user} = state}) do
    # Because some pages specifically say "Eastern"
    now = Timex.now() |> Timex.Timezone.convert("US/Eastern")

    last_logon_date = Timex.format!(now, "{0M}/{0D}/{YYYY}")
    last_logon_time = Timex.format!(now, "{h24}.{m}")

    result = Repo.transaction(fn ->
      fetch_user_for_update(user.id)
      |> change(%{
        prf_last_logon_date: last_logon_date,
        prf_last_logon_time: last_logon_time
      })
      |> Repo.update!()
    end)

    case result do
      {:ok, _updated_user} ->
        {:ok, state}
      {:error, _reason} ->
        # Log but don't fail the logoff
        Logger.warning("Failed to update last logon time for user #{user.id}")
        {:ok, state}
    end
  end

  defp end_session({:ok, %{user: user, reason: reason} = state}) do
    session_status = case reason do
      :normal -> :normal
      :disconnect -> :normal
      :abnormal -> :abnormal
    end

    SessionManager.close_session(user.id, session_status)

    log_reason = case reason do
      :disconnect -> "Disconnect"
      :normal -> "Normal"
      :abnormal -> "Abnormal"
    end

    Logger.info("User #{user.id} logged off (#{log_reason})")

    {:ok, state}
  end

  defp determine_result({:ok, %{reason: reason} = state}) do
    result = case reason do
      :disconnect -> :disconnect
      _ -> :ok
    end

    {:ok, Map.put(state, :result, result)}
  end

  defp build_response({:ok, %{request: nil} = state}) do
    # Abnormal termination - no response needed
    {:ok, state}
  end

  defp build_response({:ok, %{request: request} = state}) do
    # TODO: Determine what this timestamp should actually be
    response_payload = <<Status.SUCCESS.value(), "xxxxxxxx01011988124510">>

    response = response_payload
               |> Fm0.make_response(request)
               |> Packet.encode()

    {:ok, Map.put(state, :response, response)}
  end

  defp finalize_response({:ok, %{result: result, response: response}}, _context) do
    new_context = %Context{auth_timeout: Context.set_auth_timer()}
    {result, new_context, response}
  end

  defp finalize_response({:ok, _state}, context) do
    # Abnormal termination path - no response
    {:ok, context, nil}
  end

  # Helper functions

  defp fetch_user_for_update(user_id) do
    from(u in User,
      where: u.id == ^user_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one!()
  end

  defp build_empty_response(request) do
    <<>>
    |> Fm0.make_response(request)
    |> Packet.encode()
  end
end