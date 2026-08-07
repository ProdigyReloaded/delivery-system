defmodule Prodigy.Core.Data.Service.MemberStatus do
  @moduledoc """
  Household member account-status bits, denormalized onto `household.profile`.

  These back the TOOLS "Add/Suspend Member IDs" screen and the logon
  active check.  Logged in as the subscriber (slot A) a client cannot read
  slots B..F's own User-row fields, so per-member status rides in the
  household-level indicator bytes, which the subscriber reads/writes in one
  profile fetch.

    * PRF_SUFFIX_IN_USE_INDICATORS (0x0115, 1 byte): bit `0x01 <<< i` means
      suffix i (A..F) is allocated.
    * PRF_INDICATORS_x (A=0x0120, B=0x0129, C=0x0132, D=0x013B, E=0x0144,
      F=0x014D; 2 bytes each): byte 1 bit `0x01` = ACTIVE (0 = suspended),
      bit `0x02` = ENROLLED (0 = not yet enrolled).  Byte 2 reserved.

  Binary profile values are stored base64 in the JSONB map (a NUL "off"
  byte can't live in JSON text), so decode/encode go through `Base`.
  """

  import Bitwise

  alias Prodigy.Core.Data.Service.ProfileBackfill

  @suffix_tac 0x0115
  @indicators_tac %{
    "A" => 0x0120,
    "B" => 0x0129,
    "C" => 0x0132,
    "D" => 0x013B,
    "E" => 0x0144,
    "F" => 0x014D
  }
  @suffix_index %{"A" => 0, "B" => 1, "C" => 2, "D" => 3, "E" => 4, "F" => 5}

  @active 0x01
  @enrolled 0x02

  @type suffix :: String.t()
  @type profile :: map()

  @doc "JSONB key for the suffix-in-use byte (#277 / 0x0115)."
  @spec suffix_key() :: String.t()
  def suffix_key, do: ProfileBackfill.tac_key(@suffix_tac)

  @doc "JSONB key for a slot's PRF_INDICATORS_x byte."
  @spec indicators_key(suffix()) :: String.t()
  def indicators_key(suffix), do: ProfileBackfill.tac_key(Map.fetch!(@indicators_tac, suffix))

  # -- suffix-in-use ---------------------------------------------------

  defp first_byte(nil), do: nil

  defp first_byte(stored) when is_binary(stored) do
    case Base.decode64(stored) do
      {:ok, <<b, _::binary>>} -> b
      {:ok, <<>>} -> 0
      _ -> nil
    end
  end

  @doc "Set suffix `suffix`'s allocated bit in the profile's #277 byte."
  @spec put_suffix_in_use(profile(), suffix()) :: profile()
  def put_suffix_in_use(profile, suffix) do
    cur = first_byte(Map.get(profile, suffix_key())) || 0
    byte = cur ||| 1 <<< Map.fetch!(@suffix_index, suffix)
    Map.put(profile, suffix_key(), Base.encode64(<<byte>>))
  end

  # -- per-member indicators -------------------------------------------

  defp flags(profile, suffix), do: first_byte(Map.get(profile, indicators_key(suffix)))

  @doc """
  Whether a member's slot is active (not suspended).  A missing indicator
  (legacy household created before this model) is treated as active so
  existing logons are never blocked.
  """
  @spec active?(profile(), suffix()) :: boolean()
  def active?(profile, suffix) do
    case flags(profile, suffix) do
      nil -> true
      b -> (b &&& @active) != 0
    end
  end

  @doc "Whether a member's slot is enrolled.  Missing indicator => not enrolled."
  @spec enrolled?(profile(), suffix()) :: boolean()
  def enrolled?(profile, suffix) do
    case flags(profile, suffix) do
      nil -> false
      b -> (b &&& @enrolled) != 0
    end
  end

  defp put_flags(profile, suffix, byte) do
    Map.put(profile, indicators_key(suffix), Base.encode64(<<byte, 0x00>>))
  end

  @doc "Write a member's active/enrolled flags outright."
  @spec put_indicators(profile(), suffix(), boolean(), boolean()) :: profile()
  def put_indicators(profile, suffix, active, enrolled) do
    byte = if(active, do: @active, else: 0) ||| if(enrolled, do: @enrolled, else: 0)
    put_flags(profile, suffix, byte)
  end

  @doc "Set a member's ENROLLED bit, preserving the active bit (default active)."
  @spec set_enrolled(profile(), suffix()) :: profile()
  def set_enrolled(profile, suffix) do
    cur = flags(profile, suffix) || @active
    put_flags(profile, suffix, cur ||| @enrolled)
  end

  @doc "Suffix letter for a household user id (last character, upcased)."
  @spec suffix_of(String.t()) :: suffix()
  def suffix_of(user_id) when is_binary(user_id), do: String.upcase(String.last(user_id))
end
