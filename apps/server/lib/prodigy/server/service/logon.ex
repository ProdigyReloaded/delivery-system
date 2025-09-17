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

defmodule Prodigy.Server.Service.Logon do
  @moduledoc """
  Handle Logon requests
  """

  @behaviour Prodigy.Server.Service

  require Logger
  require Ecto.Query
  use EnumType

  import Prodigy.Core.Util
  import Ecto.Query, only: [from: 2]

  alias Comeonin.Ecto.Password
  alias Prodigy.Core.Data.{Repo, User}
  alias Prodigy.Server.Protocol.Dia.Packet
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Service.Messaging
  alias Prodigy.Server.SessionManager
  alias Prodigy.Server.Context

  @supported_versions ["06.03.10", "06.03.17"]

  defenum Status do
    @moduledoc "An enumeration of Logon service responses"

    value SUCCESS, 0x0
    value ENROLL_OTHER, 0x1
    value ENROLL_SUBSCRIBER, 0x2
    value BAD_PASSWORD, 0x5
    value ID_IN_USE, 0x7
    value BAD_VERSION, 0x9
    value ACCOUNT_PROBLEM, 0xD
  end

  @doc """
  Handles incoming logon requests
  """
  def handle(%Fm0{} = request, %Context{auth_timeout: auth_timeout} = context) do
    request
    |> parse_request()
    |> and_then(&validate_version/1)
    |> and_then(&authenticate_user/1)
    |> and_then(&validate_user_status/1)
    |> and_then(&check_enrollment/1)
    |> and_then(&begin_session/1)
    |> and_then(&build_response/1)
    |> finalize_response(context, auth_timeout)
  end

  # Railway-oriented combinator - handles any :ok tuple
  defp and_then({:error, _, _} = error, _func), do: error
  defp and_then(success_tuple, func) when elem(success_tuple, 0) == :ok, do: func.(success_tuple)

  # Pipeline functions

  defp parse_request(%Fm0{payload: <<_, user_id::binary-size(7), pwlen, password::binary-size(pwlen),
    version::binary-size(8), _rest::binary>>} = request) do
    {:ok, %{user_id: user_id, password: password, version: version, request: request, user: nil}}
  end

  defp parse_request(%Fm0{} = request) do
    {:error, Status.ACCOUNT_PROBLEM, request}
  end

  defp validate_version({:ok, %{version: version} = state}) when version in @supported_versions do
    Logger.debug("User is connecting with RS #{version}")
    {:ok, state}
  end

  defp validate_version({:ok, %{request: request}}) do
    Logger.warning("User is connecting with an unacceptable software version")
    {:error, Status.BAD_VERSION, request}
  end

  defp authenticate_user({:ok, %{user_id: user_id, password: password, request: request} = state}) do
    Logger.debug("Retrieving user '#{user_id}' (password: '#{password}')")

    user = fetch_user_with_associations(user_id)

    case user do
      nil ->
        Logger.warning("User #{user_id} attempted to logon, but does not exist in the database")
        {:error, Status.BAD_PASSWORD, request}

      user ->
        case verify_password(user, password) do
          :ok ->
            {:ok, Map.put(state, :user, user)}
          :error ->
            Logger.warning("User #{user.id} attempted logon, but failed authentication")
            {:error, Status.BAD_PASSWORD, request}
        end
    end
  end

  defp validate_user_status({:ok, %{user: user, request: request} = state}) do
    cond do
      user_deleted?(user) ->
        Logger.debug("User is deleted")
        {:error, Status.ACCOUNT_PROBLEM, request}

      not household_active?(user) ->
        Logger.debug("Household inactive")
        {:error, Status.ACCOUNT_PROBLEM, request}

      true ->
        {:ok, state}
    end
  end

  defp check_enrollment({:ok, %{user: user} = state}) do
    normalized_user_id = String.upcase(user.id)

    enrollment = cond do
      user.date_enrolled != nil ->
        Logger.debug("User is enrolled")
        :enrolled

      String.ends_with?(normalized_user_id, "A") ->
        Logger.debug("Subscriber is unenrolled")
        :enroll_subscriber

      true ->
        Logger.debug("Household member is unenrolled")
        :enroll_other
    end

    {:ok, Map.put(state, :enrollment, enrollment)}
  end

  defp begin_session({:ok, %{user: user, enrollment: enrollment, version: version, request: request} = state}) do
    session_status = case enrollment do
      :enrolled -> :success
      :enroll_subscriber -> :enroll_subscriber
      :enroll_other -> :enroll_other
    end

    case SessionManager.create_session(user, session_status, version) do
      {:ok, session} ->
        status = case enrollment do
          :enrolled -> Status.SUCCESS
          :enroll_subscriber -> Status.ENROLL_SUBSCRIBER
          :enroll_other -> Status.ENROLL_OTHER
        end
        {:ok, state |> Map.put(:status, status) |> Map.put(:session_id, session.id)}

      {:error, :concurrency_exceeded} ->
        Logger.warning("User #{user.id} attempted logon, but exceeded concurrency limit")
        {:error, Status.ID_IN_USE, request}
    end
  end

  defp build_response({:ok, %{status: status, user: user, session_id: session_id, request: request} = state}) do
    response = make_response_payload({status, user, session_id})
               |> Fm0.make_response(request)
               |> Packet.encode()

    {:ok, Map.put(state, :response, response)}
  end

  defp finalize_response({:ok, %{status: status, user: user, session_id: session_id, version: version, response: response}}, _context, auth_timeout) do
    Context.cancel_auth_timer(auth_timeout)

    log_message = case status do
      Status.SUCCESS -> "logged on (Normal)"
      Status.ENROLL_SUBSCRIBER -> "logged on (Enroll Subscriber)"
      Status.ENROLL_OTHER -> "logged on (Enroll Other)"
    end

    Logger.info("User #{user.id} #{log_message}")

    new_context = %Context{
      user: user,
      session_id: session_id,
      rs_version: version
    }

    {:ok, new_context, response}
  end

  defp finalize_response({:error, status, request}, context, _auth_timeout) do
    response = make_response_payload({status, nil, nil})
               |> Fm0.make_response(request)
               |> Packet.encode()

    {:error, context, response}
  end

  # Helper functions

  defp fetch_user_with_associations(user_id) do
    from(u in User,
      where: u.id == ^user_id,
      preload: [:household, :data_collection_policy]
    )
    |> Repo.one()
  end

  defp verify_password(user, password) do
    # TODO: Remove this once tooling supports creating users with initial password hashed
    encrypted_pw = if String.starts_with?(user.password, "$pbkdf2-sha512$") do
      user.password
    else
      Pbkdf2.hash_pwd_salt(user.password)
    end

    if Password.valid?(password, encrypted_pw) do
      Logger.debug("Retrieved user with matching password")
      :ok
    else
      :error
    end
  end

  defp user_deleted?(user) do
    user.date_deleted != nil
  end

  defp household_active?(user) do
    user.household.disabled_date == nil and user.household.enabled_date != nil
  end

  # Response payload building

  def make_response_payload({Status.SUCCESS, user, _session_id}) do
    {date, time} = get_formatted_datetime()
    new_mail_indicator = bool2int(Messaging.unread_messages?(user))
    data_collection = build_data_collection_bits(user)
    {last_logon_date, last_logon_time} = get_last_logon_info(user)

    <<
      0x0,
      "M",                              # TODO: set PRF_GENDER from user record
      data_collection::binary,
      0x0,                              # unknown
      0x0,                              # PRF_BUSINESS_CLIENT_CODE
      0x0,                              # PRF_USER_SECURITY_LEVEL
      0x0,                              # PRF_AUTO_SKIP
      0x0,                              # PRF_GAME_PROFILE
      date::binary-size(6),
      time::binary-size(6),
      new_mail_indicator,
      0x0::16,                          # PRF_CUG_ID
      0x0::16,                          # ??
      0x0::16,                          # PRF_CUG_SERVICE_ID
      0x0::16,                          # PRF_USER_CLASS
      0::16,                            # PRF_TIER_OF_SERVICE
      0::16,                            # PRF_CCL_VERSION_NUM
      0,                                # PRF_SEL_NUM_ITEMS
      0,
      0::16,
      last_logon_date::binary-size(8),
      last_logon_time::binary-size(5)
    >>
  end

  def make_response_payload({status, _, _}) do
    {date, time} = get_formatted_datetime()

    <<
      status.value(),
      0x0::80,
      date::binary-size(6),
      time::binary-size(6),
      0x0::56
    >>
  end

  defp get_formatted_datetime do
    now = Calendar.DateTime.now_utc()
    date = Calendar.strftime(now, "%m%d%y")
    time = Calendar.strftime(now, "%H%M%S")
    {date, time}
  end

  defp get_last_logon_info(user) do
    last_logon_date = val_or_else(user.prf_last_logon_date, "        ")
    last_logon_time = val_or_else(user.prf_last_logon_time, "     ")
    {last_logon_date, last_logon_time}
  end

  defp build_data_collection_bits(user) do
    policy = cond do
      not Ecto.assoc_loaded?(user.data_collection_policy) -> nil
      true -> user.data_collection_policy
    end

    case policy do
      nil ->
        <<0::32>>

      policy ->
        encode_data_collection_policy(policy)
    end
  end

  defp encode_data_collection_policy(policy) do
    <<
      1::1,
      0::3,
      bool2int(policy.ad)::1,        # 'A'
      bool2int(policy.pwindow)::1,   # 'W'
      bool2int(policy.element)::1,   # 'E'
      bool2int(policy.template)::1,  # 'T'

      # Function codes
      bool2int(policy.exit)::1,      # 'E'
      bool2int(policy.undo)::1,      # 'U'
      bool2int(policy.path)::1,      # 'P'
      bool2int(policy.help)::1,      # 'H'
      bool2int(policy.jump)::1,      # 'J'
      bool2int(policy.back)::1,      # 'B'
      bool2int(policy.next)::1,      # 'N'
      bool2int(policy.commit)::1,    # 'C'
      0::6,
      bool2int(policy.action)::1,    # 'A'
      bool2int(policy.look)::1,      # 'L'
      0::8
    >>
  end
end