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

defmodule Prodigy.Core.Data.Service.Enroller do
  @moduledoc """
  Shared household + subscriber creation logic. Callers:

  * `Prodigy.OdbUtil.Create` - the pomsutil `create` subcommand.
  * `Prodigy.Portal.SignupWizardLive` - the in-browser signup flow.

  Previously this lived as inline code inside pomsutil's Create module
  with `IO.puts` / `exit({:shutdown, N})` error handling suited to a
  CLI. Pulled into `:core` so the LiveView can call it in a more robust
  manner.
  """

  import Ecto.Changeset

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, User}

  @type option ::
          {:concurrency_limit, non_neg_integer()}
          | {:enroll_name, {String.t(), String.t()} | nil}
          | {:portal_user_id, integer() | nil}

  @doc """
  Create a new household and its primary (`A`) subscriber.

  `household_id` is the 6-char prefix; the user id is derived as
  `household_id <> "A"`. Both sides are inserted in a single Ecto
  transaction - partial creation is not possible.

  Options:

    * `:concurrency_limit` - integer, default 1. Pass 0 for unlimited.
    * `:enroll_name` - `{first, last}` tuple. When given, stamps
      `date_enrolled`, `first_name`, `last_name`, default gender/title
      onto the user and mirrors `user_a_first`/`_last`/`_title` onto
      the household. When nil (the default), the user is blank and
      will hit the enrollment wizard on first logon.
    * `:portal_user_id` - portal-user foreign key to associate the
      new subscriber with. Nil for CLI-created users, set for
      signup-wizard users so the admin UI can surface the link.

  Returns `{:ok, {%Household{}, %User{}}}` or `{:error, reason}`.
  Reasons: `:household_exists`, `{:changeset, %Ecto.Changeset{}}`,
  or a raw `Ecto.Multi` failure tuple.
  """
  @spec create_subscriber(String.t(), String.t(), [option]) ::
          {:ok, {Household.t(), User.t()}} | {:error, term}
  def create_subscriber(household_id, password, opts \\ [])
      when is_binary(household_id) and is_binary(password) do
    concurrency_limit = Keyword.get(opts, :concurrency_limit, 1)
    enroll_name = Keyword.get(opts, :enroll_name)
    portal_user_id = Keyword.get(opts, :portal_user_id)

    cond do
      concurrency_limit < 0 ->
        {:error, {:bad_concurrency_limit, concurrency_limit}}

      Repo.get(Household, household_id) != nil ->
        {:error, :household_exists}

      true ->
        do_create(household_id, password, concurrency_limit, enroll_name, portal_user_id)
    end
  end

  defp do_create(household_id, password, concurrency_limit, enroll_name, portal_user_id) do
    today = DateTime.to_date(DateTime.utc_now())
    user_id = household_id <> "A"

    household_changeset =
      %Household{id: household_id, enabled_date: today}
      |> change(%{profile: household_profile(enroll_name)})
      |> put_assoc(:users, [
        %User{
          id: user_id,
          concurrency_limit: concurrency_limit,
          portal_user_id: portal_user_id
        }
        |> User.changeset(user_attrs(enroll_name, today, password))
      ])

    case Repo.insert(household_changeset) do
      {:ok, %Household{users: [user | _]} = household} ->
        {:ok, {household, user}}

      {:error, changeset} ->
        {:error, {:changeset, changeset}}
    end
  end

  # With --enroll / :enroll_name, stamp date_enrolled + a minimal JSONB
  # profile so the Logon service treats the account as already enrolled.
  # The name TACs go straight into the profile map.
  defp user_attrs(nil, _today, password), do: %{password: password}

  defp user_attrs({first, last}, today, password) do
    %{
      password: password,
      date_enrolled: today,
      profile: %{
        # 0x015F first_name, 0x015E last_name, 0x0161 title, 0x0157 gender
        "015F" => first,
        "015E" => last,
        "0161" => "Mr.",
        "0157" => "M"
      }
    }
  end

  # Mirror name/title into the household's "A" slot JSONB - the
  # denormalized copy the original RS client reads by TAC. Keeps
  # parity with the admin Users-tab edit flow.
  defp household_profile(nil), do: %{}

  defp household_profile({first, last}) do
    %{
      # 0x011B user_a_first, 0x011A user_a_last, 0x011D user_a_title
      "011B" => first,
      "011A" => last,
      "011D" => "Mr."   # TODO add an argument for this.
    }
  end
end
