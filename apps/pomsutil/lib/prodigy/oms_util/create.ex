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

defmodule Create do
  @moduledoc """
  CLI wrapper around `Prodigy.Core.Data.Service.Enroller.create_subscriber/3`.
  Handles argument parsing, random id/password generation, and turns
  Enroller's structured errors into `IO.puts` + `exit({:shutdown, N})`
  output shaped the way scripts expect.
  """

  alias Prodigy.Core.Data.Service.Enroller

  def exec(argv, args \\ %{}) do
    {household_id, password} = parse_arguments(argv)
    concurrency_limit = Map.get(args, :concurrency_limit, 1)
    enroll_name = parse_enroll_name(Map.get(args, :enroll))

    case Enroller.create_subscriber(
           household_id,
           password,
           concurrency_limit: concurrency_limit,
           enroll_name: enroll_name
         ) do
      {:ok, {_household, user}} ->
        IO.puts("- Created Household #{household_id}")
        IO.puts("- Created User #{user.id} with password #{password}")

        limit_msg =
          if concurrency_limit == 0 do
            "unlimited concurrent sessions"
          else
            "#{concurrency_limit} concurrent session(s)"
          end

        IO.puts("   * Concurrency limit: #{limit_msg}")

        if enroll_name do
          {first, last} = enroll_name
          IO.puts("   * Pre-enrolled as #{first} #{last}")
        end

      {:error, :household_exists} ->
        IO.puts("Error: Household #{household_id} already exists")
        exit({:shutdown, 1})

      {:error, {:bad_concurrency_limit, _}} ->
        IO.puts("Error: Concurrency limit must be 0 (unlimited) or a positive integer")
        exit({:shutdown, 1})

      {:error, {:changeset, changeset}} ->
        IO.puts("Error: #{inspect(changeset.errors)}")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # Parse the --enroll "First Last" string into a {first, last} tuple.
  # Multi-word last names end up in `last`; the first whitespace-separated
  # token is first_name, everything after that is last_name. Quiet no-op
  # when the flag isn't present.
  defp parse_enroll_name(nil), do: nil

  defp parse_enroll_name(str) when is_binary(str) do
    case String.split(str, ~r/\s+/, parts: 2, trim: true) do
      [first, last] -> {first, last}
      [only] -> {only, ""}
      _ -> nil
    end
  end

  defp parse_arguments(argv) do
    case argv do
      [] ->
        # No arguments - generate random household and password
        {random_id(), random_password()}

      [household_spec] ->
        # One argument - could be XXXX or XXXXYY
        household_id = parse_household_id(household_spec)
        {household_id, random_password()}

      [household_spec, password] ->
        # Two arguments - household spec and password
        household_id = parse_household_id(household_spec)
        validated_password = validate_password(password)
        {household_id, validated_password}

      _ ->
        IO.puts("Error: Too many arguments")
        exit({:shutdown, 1})
    end
  end

  defp parse_household_id(spec) do
    cond do
      # Check if it's exactly 4 letters (XXXX)
      String.length(spec) == 4 and String.match?(spec, ~r/^[A-Z]{4}$/) ->
        spec <> random_digits(2)

      # Check if it's 6 characters (XXXXYY)
      String.length(spec) == 6 and String.match?(spec, ~r/^[A-Z]{4}[0-9]{2}$/) ->
        spec

      # Invalid format
      true ->
        IO.puts("Error: Invalid household ID format. Must be XXXX (4 letters) or XXXXYY (4 letters + 2 digits)")
        exit({:shutdown, 1})
    end
  end

  defp validate_password(password) do
    cond do
      String.length(password) < 2 ->
        # The DOS RS client refuses to initiate a TCS connection with
        # a 1-character password; gate it up front so pomsutil-created
        # users never land in an unusable state.
        IO.puts("Error: Password must be at least 2 characters")
        exit({:shutdown, 1})

      String.length(password) > 10 ->
        IO.puts("Error: Password cannot be longer than 10 characters")
        exit({:shutdown, 1})

      not String.match?(password, ~r/^[A-Z0-9]+$/) ->
        IO.puts("Error: Password must contain only uppercase letters and digits")
        exit({:shutdown, 1})

      true ->
        password
    end
  end

  defp random(x) do
    Enum.to_list(x)
    |> Enum.chunk_every(1)
    |> Enum.random()
  end

  defp random_char do
    random(?A..?Z)
  end

  defp random_int do
    random(?0..?9)
  end

  defp random_both do
    random(Enum.chunk_every(?0..?9, 1) ++ Enum.chunk_every(?A..?Z, 1))
  end

  defp random_digits(count) do
    Enum.map_join(0..(count - 1), fn _ -> random_int() end)
  end

  defp random_id do
    random_4 = Enum.map_join(0..3, fn _ -> random_char() end)
    random_2 = random_digits(2)
    Enum.join([random_4, random_2], "")
  end

  defp random_password do
    Enum.map_join(0..5, fn _ -> random_both() end)
  end
end
