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

defmodule Prodigy.Portal.SignupIds do
  @moduledoc """
  Helpers for the signup wizard: generate random 6-char household ids
  (that become a 7-char subscriber id with a trailing "A"), validate
  user-typed ids against format + reserved-prefix + uniqueness rules,
  and generate wire-contract-shaped passwords.

  Generation uses a consonant-only alphabet (no vowels, no Y) modeled
  on the real Prodigy id space. Custom input relaxes to full A-Z since
  the user is explicitly choosing letters.

  Reserved prefixes are embedded as a module attribute - starter list
  covering operator codes, common first names (PHIL is reserved for
  the maintainer), famous US broadcast call signs, common abbreviations,
  and a handful of obvious profanity. Grow the list in source as gaps
  show up in real use; admin-editable storage is a later enhancement.
  """

  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{Household, User}

  @consonants ~c"BCDFGHJKLMNPQRSTVWXZ"

  # Names / call signs / abbreviations we don't want random users to
  # grab. An operator in possession of `service_users.any_userid` can
  # bypass this list (see `validate_custom/2`).
  @reserved_prefixes MapSet.new(
                      ~w(
                        HELP EXPT DEMO TEST MODT INFO ADMN ROOT USER NULL VOID
                        PHIL
                        JOHN MARY SARA MIKE JANE JACK ANNA BETH CARL DANA ERIC
                        GARY KATE LISA MARK NICK PAUL ROSE TODD ANDY JAKE BILL
                        DAVE FRED HANK JAKE JOEL JOSH KYLE LUKE NOAH OLIV OWEN
                        PETE RYAN SCOT SETH TINA TONY TYLE VICT WILL ZACH
                        WABC WCBS WNBC WNYC WKRP WXYZ WBAL WBZZ KTLA KNBC KCBS
                        KABC KFWB KMPX KGON KOMO KNX KROQ KUSC
                        USPS USPT NASA USAF USMC USCG USNA NYPD LAPD LASD
                        NCAA NFLX NBAA NHLL MLBB MPAA RIAA AMPAS PETA
                      )
                    )

  # Always-refused regardless of scope. Kept separate so the
  # `bypass_reserved?` switch only affects the first list.
  @profanity_prefixes MapSet.new(
                       ~w(
                         FUCK SHIT DAMN HELL CRAP DICK COCK TITS CUNT PISS
                         SLUT NAZI
                       )
                     )

  @doc """
  Generate a random acceptable household id (6 chars: 4 consonants +
  2 digits). Retries up to `max_tries` times on a reserved-prefix or
  already-taken collision. Returns `{:ok, household_id}` or
  `{:error, :exhausted}` in the vanishingly-rare case where we can't
  find one - the id space is ~45M slots so this should never happen.
  """
  def generate(max_tries \\ 25) do
    do_generate(max_tries)
  end

  defp do_generate(0), do: {:error, :exhausted}

  defp do_generate(tries) do
    id = fresh_id()

    case reserved_or_taken?(id) do
      :ok -> {:ok, id}
      _ -> do_generate(tries - 1)
    end
  end

  defp fresh_id do
    letters = for _ <- 1..4, into: "", do: <<Enum.random(@consonants)>>
    digits = :rand.uniform(100) - 1
    letters <> String.pad_leading(Integer.to_string(digits), 2, "0")
  end

  @doc """
  Validate a user-typed household id. Input must be 6 chars: 4 A-Z
  letters + 2 digits. Returns `:ok` or `{:error, reason}` where reason
  is `:bad_format | :reserved | :profanity | :taken`. Custom input is
  explicitly permitted to include vowels; only the random path
  restricts to consonants.

  ## Options

    * `:bypass_reserved` - default `false`. When `true`, the
      `@reserved_prefixes` (names / call signs / abbreviations) list
      is skipped; profanity is still refused. Set this when the
      caller holds the `service_users.any_userid` scope.
  """
  def validate_custom(id, opts \\ [])

  def validate_custom(id, opts) when is_binary(id) do
    bypass? = Keyword.get(opts, :bypass_reserved, false)

    cond do
      not String.match?(id, ~r/^[A-Z]{4}[0-9]{2}$/) ->
        {:error, :bad_format}

      profanity?(id) ->
        {:error, :profanity}

      not bypass? and reserved?(id) ->
        {:error, :reserved}

      taken?(id) ->
        {:error, :taken}

      true ->
        :ok
    end
  end

  def validate_custom(_, _), do: {:error, :bad_format}

  @doc "Lowercase/mixed-case passthrough: canonicalize to uppercase first."
  def normalize(id) when is_binary(id), do: id |> String.upcase() |> String.trim()
  def normalize(_), do: ""

  @doc """
  Generate an 8-char password using the same A-Z / 2-9 alphabet as the
  admin Users tab's reset-password flow - skips visually-ambiguous
  characters (I, O, 0, 1) so the generated value reads cleanly over
  the phone and satisfies the DOS RS client's uppercase-and-digits wire
  contract.
  """
  def generate_password do
    alphabet = ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    len = length(alphabet)
    for _ <- 1..8, into: "", do: <<Enum.at(alphabet, :rand.uniform(len) - 1)>>
  end

  # ------------------------------------------------------------------

  defp reserved_or_taken?(id) do
    cond do
      profanity?(id) -> {:error, :profanity}
      reserved?(id) -> {:error, :reserved}
      taken?(id) -> {:error, :taken}
      true -> :ok
    end
  end

  defp reserved?(id) do
    MapSet.member?(@reserved_prefixes, String.slice(id, 0, 4))
  end

  defp profanity?(id) do
    MapSet.member?(@profanity_prefixes, String.slice(id, 0, 4))
  end

  defp taken?(household_id) do
    user_id = household_id <> "A"

    Repo.exists?(
      from h in Household,
        where: h.id == ^household_id
    ) or
      Repo.exists?(
        from u in User,
          where: u.id == ^user_id
      )
  end
end
