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

defmodule Prodigy.Server.Service.Logon do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  Handle Logon requests
  """

  require Logger
  require Ecto.Query
  use EnumType

  import Prodigy.Server.Util

  alias Comeonin.Ecto.Password
  alias Prodigy.Core.Data.{Repo, User}
  alias Prodigy.Server.Protocol.Dia.Packet
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0
  alias Prodigy.Server.Service.Messaging
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
            # 'A'
            bool2int(user.data_collection_policy.ad)::1,
            # 'W'
            bool2int(user.data_collection_policy.pwindow)::1,
            # 'E'
            bool2int(user.data_collection_policy.element)::1,
            # 'T'
            bool2int(user.data_collection_policy.template)::1,

            # function codes
            # 'E'
            bool2int(user.data_collection_policy.exit)::1,
            # 'U'
            bool2int(user.data_collection_policy.undo)::1,
            # 'P'
            bool2int(user.data_collection_policy.path)::1,
            # 'H'
            bool2int(user.data_collection_policy.help)::1,
            # 'J'
            bool2int(user.data_collection_policy.jump)::1,
            # 'B'
            bool2int(user.data_collection_policy.back)::1,
            # 'N'
            bool2int(user.data_collection_policy.next)::1,
            # 'C'
            bool2int(user.data_collection_policy.commit)::1,
            0::6,
            # 'A'
            bool2int(user.data_collection_policy.action)::1,
            # 'L'
            bool2int(user.data_collection_policy.look)::1,
            0::8
          >>
      end

    last_logon_date = val_or_else(user.prf_last_logon_date, "        ")
    last_logon_time = val_or_else(user.prf_last_logon_date, "     ")

    res = <<
      0x0,
      # TODO set PRF_GENDER from user record, N.B. nil breaks encoding
      "M",
      #      0x0::unsigned-integer-size(32), # TODO implement data collection
      data_collection::binary,
      # unknown
      0x0,
      # PRF_BUSINESS_CLIENT_CODE
      0x0,
      # PRF_USER_SECURITY_LEVEL
      0x0,
      # PRF_AUTO_SKIP
      0x0,
      # PRF_GAME_PROFILE
      0x0,
      # SYS_DATE
      date::binary-size(6)-unit(8),
      # SYS_TIME
      time::binary-size(6)-unit(8),
      new_mail_indicator,
      # PRF_CUG_ID
      0x0::16,
      # ??
      0x0::16,
      # "TL",                           # PRF_CUG_SERVICE_ID
      0x0::16,
      # PRF_USER_CLASS
      0x0::unsigned-integer-size(16),

      # tlpeadds shows some more, including the last logon date and time, let's see
      # yup! works for 6.03.17.  what about older? yup, works for 6.03.10
      #
      0::16,
      # PRF_TIER_OF_SERVICE
      0::16,
      # PRF_CCL_VERSION_NUM
      0,
      # PRF_SEL_NUM_ITEMS
      0,
      #
      0::16,
      # PRF_LAST_LOGON_DATE
      last_logon_date::binary-size(8),
      # PRF_LAST_LOGON_TIME
      last_logon_time::binary-size(5)
      # PRF_SEL_ITEM_LIST::2
    >>

    Logger.debug("logon response: #{inspect(res, base: :hex, limit: :infinity)}")
    res
  end

  def make_response_payload({status, _}) do
    now = Calendar.DateTime.now_utc()
    # TODO refactor to use Timex
    date = now |> Calendar.strftime("%m%d%y")
    # TODO refactor to use Timex
    time = now |> Calendar.strftime("%H%M%S")

    <<
      status.value,
      0x0::unsigned-integer-size(80),
      # SYS_DATE
      date::binary-size(6)-unit(8),
      # SYS_TIME
      time::binary-size(6)-unit(8),
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

    # TODO it is a case insensitive match from the user perspective; RS uppercases whatever is given, so we should
    #   do the same.
    if user == nil do
      Logger.warn("User #{user_id} attempted to logon, but does not exist in the database")
      :bad_password
      #      true -> case Comeonin.Ecto.Password.valid?(password, user.password) do
    else
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
          Logger.warn("User #{user_id} attempted logon, but failed authentication")
          # should match when password doesn't match or no user
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
        mark_id_in_use(user)
        {:enroll_subscriber, user}

      true ->
        Logger.debug("Household member is unenrolled")
        mark_id_in_use(user)
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

  defp in_use(user) do
    case user.logged_on do
      false ->
        false

      nil ->
        false

      true ->
        Logger.warn("User #{user.id} attempted logon, but appears to already be logged on")
        :id_in_use
    end
  end

  defp mark_id_in_use(user) do
    user
    |> Ecto.Changeset.change(%{logged_on: true})
    |> Repo.update!()

    Logger.debug("User online state updated")
    :ok
  end

  defp version_ok(version) do
    if version in ["06.03.10", "06.03.17"] do
      Logger.debug("User is connecting with RS #{version}")
      true
    else
      Logger.warn("User is connecting with an unacceptable software version")
      :bad_version
    end
  end

  def handle(
        %Fm0{
          payload:
            <<_, user_id::binary-size(7)-unit(8), pwlen, password::binary-size(pwlen)-unit(8),
              version::binary-size(8)-unit(8), _rest::binary>>
        } = request,
        %Session{auth_timeout: auth_timeout}
      ) do
    result =
      with true <- version_ok(version),
           {:ok, user} <- get_user(user_id, password),
           false <- in_use(user),
           false <- deleted(user),
           true <- household_active(user),
           true <- enrolled(user),
           :ok <- mark_id_in_use(user) do
        {Status.SUCCESS, user}
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
        {:error, %Session{}, response}
    end
  end
end
