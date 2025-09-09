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

defmodule Prodigy.Server.Service.Logon do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Logon requests
  """

  require Logger
  require Ecto.Query
  use EnumType

  import Prodigy.Core.Util

  alias Comeonin.Ecto.Password
  alias Prodigy.Core.Data.{Repo, User}
  alias Prodigy.Server.Protocol.Dia.Packet
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Service.Messaging
  alias Prodigy.Server.SessionManager
  alias Prodigy.Server.Session

  defenum Status do
    @moduledoc "An enumeration of Logon service responses"

    value SUCCESS, 0x0 do
      @moduledoc false
    end

    value ENROLL_OTHER, 0x1 do
      @moduledoc false
    end

    value ENROLL_SUBSCRIBER, 0x2 do
      @moduledoc false
    end

    value BAD_PASSWORD, 0x5 do
      @moduledoc false
    end

    value ID_IN_USE, 0x7 do
      @moduledoc false
    end

    value BAD_VERSION, 0x9 do
      @moduledoc false
    end

    value ACCOUNT_PROBLEM, 0xD do
      @moduledoc false
    end
  end

  def make_response_payload({Status.SUCCESS, user}) do
    now = Calendar.DateTime.now_utc()
    # TODO refactor to use Timex
    date = now |> Calendar.strftime("%m%d%y")
    # TODO refactor to use Timex
    time = now |> Calendar.strftime("%H%M%S")

    Logger.debug("user record: #{inspect(user, limit: :infinity)}")
    new_mail_indicator = bool2int(Messaging.unread_messages?(user))

    data_collection =
      cond do
        Ecto.assoc_loaded?(user.data_collection_policy) == false ->
          <<0::32>>

        user.data_collection_policy == nil ->
          <<0::32>>

        true ->
          # these constants may not be entirely right - see rs-rsk-c.pdf, page # 124
          _dc = user.data_collection_policy

          <<
            1::1,
            0::3,
            bool2int(user.data_collection_policy.ad)::1,        # 'A'
            bool2int(user.data_collection_policy.pwindow)::1,   # 'W'
            bool2int(user.data_collection_policy.element)::1,   # 'E'
            bool2int(user.data_collection_policy.template)::1,  # 'T'

            # function codes
            bool2int(user.data_collection_policy.exit)::1,      # 'E'
            bool2int(user.data_collection_policy.undo)::1,      # 'U'
            bool2int(user.data_collection_policy.path)::1,      # 'P'
            bool2int(user.data_collection_policy.help)::1,      # 'H'
            bool2int(user.data_collection_policy.jump)::1,      # 'J'
            bool2int(user.data_collection_policy.back)::1,      # 'B'
            bool2int(user.data_collection_policy.next)::1,      # 'N'
            bool2int(user.data_collection_policy.commit)::1,    # 'C'
            0::6,
            bool2int(user.data_collection_policy.action)::1,    # 'A'
            bool2int(user.data_collection_policy.look)::1,      # 'L'
            0::8
          >>
      end

    last_logon_date = val_or_else(user.prf_last_logon_date, "        ")
    last_logon_time = val_or_else(user.prf_last_logon_date, "     ")

    res = <<
      0x0,
      "M",                              # TODO set PRF_GENDER from user record, N.B. nil breaks encoding
      data_collection::binary,
      0x0,                              # unknown
      0x0,                              # PRF_BUSINESS_CLIENT_CODE
      0x0,                              # PRF_USER_SECURITY_LEVEL
      0x0,                              # PRF_AUTO_SKIP
      0x0,                              # PRF_GAME_PROFILE
      date::binary-size(6)-unit(8),     # SYS_DATE
      time::binary-size(6)-unit(8),     # SYS_TIME
      new_mail_indicator,
      0x0::16,                          # PRF_CUG_ID
      0x0::16,                          # ??
      0x0::16,                          # PRF_CUG_SERVICE_ID
      0x0::unsigned-integer-size(16),   # PRF_USER_CLASS

      # Additional information expected by TLPEADDS
      0::16,                            # PRF_TIER_OF_SERVICE
      0::16,                            # PRF_CCL_VERSION_NUM
      0,                                # PRF_SEL_NUM_ITEMS
      0,
      0::16,
      last_logon_date::binary-size(8),  # PRF_LAST_LOGON_DATE
      last_logon_time::binary-size(5)   # PRF_LAST_LOGON_TIME
      # PRF_SEL_ITEM_LIST::2
    >>

    Logger.debug("logon response: #{inspect(res, base: :hex, limit: :infinity)}")
    res
  end

  def make_response_payload({status, _}) do
    now = Calendar.DateTime.now_utc()
    date = now |> Calendar.strftime("%m%d%y")
    time = now |> Calendar.strftime("%H%M%S")

    <<
      status.value,
      0x0::unsigned-integer-size(80),
      date::binary-size(6)-unit(8),   # SYS_DATE
      time::binary-size(6)-unit(8),   # SYS_TIME
      0x0::unsigned-integer-size(56)
    >>
  end

  defp get_user(user_id, password) do
    # TODO need to check the household if user_id ends in A and there is no User record
    user =
      User
      |> Ecto.Query.where(id: ^user_id)
      |> Ecto.Query.first()
      |> Ecto.Query.preload([:household])
      |> Ecto.Query.preload([:data_collection_policy])
      |> Repo.one()

    Logger.debug("retrieving user '#{user_id} (password: '#{password}')")
    Logger.debug("#{inspect(user)}")

    if user == nil do
      Logger.warning("User #{user_id} attempted to logon, but does not exist in the database")
      :bad_password
    else
      # TODO remove this once tooling supports creating users with initial password hashed
      encrypted_pw =
        case String.starts_with?(user.password, "$pbkdf2-sha512$") do
          true -> user.password
          false -> Pbkdf2.hash_pwd_salt(user.password)
        end

      case Password.valid?(password, encrypted_pw) do
        true ->
          Logger.debug("retrieved user with matching password")
          {:ok, user}

        false ->
          Logger.warning("User #{user_id} attempted logon, but failed authentication")
          :bad_password
      end
    end
  end

  defp enrolled(user) do
    normalized_user_id = String.upcase(user.id)

    cond do
      # TODO check date_enrolled is today or prior
      user.date_enrolled != nil ->
        Logger.debug("User is enrolled")
        true

      String.ends_with?(normalized_user_id, "A") ->
        Logger.debug("Subscriber is unenrolled")
        {:enroll_subscriber, user}

      true ->
        Logger.debug("Household member is unenrolled")
        {:enroll_other, user}
    end
  end

  defp household_active(user) do
    # TODO check enabled_date is today or earlier and disabled_date is nil or after today
    if user.household.disabled_date == nil and user.household.enabled_date != nil do
      true
    else
      Logger.debug("household inactive")
      :account_problem
    end
  end

  defp deleted(user) do
    # TODO check that date_deleted is nil or after today
    if user.date_deleted == nil do
      false
    else
      Logger.debug("User is deleted")
      :account_problem
    end
  end

  defp version_ok(version) do
    if version in ["06.03.10", "06.03.17"] do
      Logger.debug("User is connecting with RS #{version}")
      true
    else
      Logger.warning("User is connecting with an unacceptable software version")
      :bad_version
    end
  end

  def handle(
        %Fm0{
          payload:
            <<_, user_id::binary-size(7)-unit(8), pwlen, password::binary-size(pwlen)-unit(8),
              version::binary-size(8)-unit(8), _rest::binary>>
        } = request,
        %Session{auth_timeout: auth_timeout} = session
      ) do
    result =
      with true <- version_ok(version),
           {:ok, user} <- get_user(user_id, password),
           false <- deleted(user),
           true <- household_active(user),
           enrollment_status <- enrolled(user) do

        # create session based on enrollment status
        session_status = case enrollment_status do
          true -> :success
          {:enroll_subscriber, _} -> :enroll_subscriber
          {:enroll_other, _} -> :enroll_other
        end

        case SessionManager.create_session(user, session_status, version) do
          {:ok, _db_session} ->
            case enrollment_status do
              true -> {Status.SUCCESS, user}
              {:enroll_subscriber, user} -> {Status.ENROLL_SUBSCRIBER, user}
              {:enroll_other, user} -> {Status.ENROLL_OTHER, user}
            end
          {:error, :concurrency_exceeded} ->
            Logger.warning("User #{user.id} attempted logon, but exceeded concurrency limit")
            {Status.ID_IN_USE, nil}
        end
      else
        :bad_version -> {Status.BAD_VERSION, nil}
        :bad_password -> {Status.BAD_PASSWORD, nil}
        {:enroll_subscriber, user} -> {Status.ENROLL_SUBSCRIBER, user}
        {:enroll_other, user} -> {Status.ENROLL_OTHER, user}
        :id_in_use -> {Status.ID_IN_USE, nil}
        _ -> {Status.ACCOUNT_PROBLEM, nil}
      end

    response =
      make_response_payload(result)
      |> Fm0.make_response(request)
      |> Packet.encode()

    case result do
      {Status.SUCCESS, user} ->
        Session.cancel_auth_timer(auth_timeout)
        Logger.info("User #{user_id} logged on (Normal)")
        {:ok, %Session{user: user, rs_version: version}, response}

      {Status.ENROLL_SUBSCRIBER, user} ->
        Session.cancel_auth_timer(auth_timeout)
        Logger.info("User #{user_id} logged on (Enroll Subscriber)")
        {:ok, %Session{user: user, rs_version: version}, response}

      {Status.ENROLL_OTHER, user} ->
        Session.cancel_auth_timer(auth_timeout)
        Logger.info("User #{user_id} logged on (Enroll Other)")
        {:ok, %Session{user: user, rs_version: version}, response}

      _ ->
        {:error, session, response}
    end
  end
end
