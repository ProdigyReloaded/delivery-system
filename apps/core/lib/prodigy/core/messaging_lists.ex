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

defmodule Prodigy.Core.MessagingLists do
  @moduledoc """
  Context module for the personal address book + mailing list features.
  Backs `Prodigy.Server.Service.AddressBook`'s DIA wire handler with all
  the CRUD against the three schemas (`AddressBookEntry`, `MailingList`,
  `MailingListMember`).
  """

  import Ecto.Query

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.{AddressBookEntry, MailingList, MailingListMember, User}

  @doc """
  Resolve a list of recipient strings (whatever the user typed in the
  compose-page "other" field - nicknames, mailing-list names, or raw
  Prodigy IDs the client routed here) into:

    * `resolved` - a deduplicated list of real `users.id` values that
      should receive the message
    * `failed`   - a deduplicated list of the original candidate strings
      that could not be resolved to a valid user (so the caller can
      synthesize a Return-to-Sender bounce notification)

  Precedence (chosen for least astonishment - a name the user explicitly
  filed in their address book resolves to that person before it is treated
  as anything else):

    1. Match against the owner's **address-book nicknames first**. If found,
       resolve to the entry's `target_user_id`. (One address resolution
       beats list expansion.)
    2. Else match against the owner's **mailing-list names**. If found,
       expand to the list's member nicknames and re-resolve those.
    3. Else treat as a **literal user ID** and verify the user exists. If
       not, the original string lands in `failed`.

  Returns `{resolved_ids, failed_strings}`.
  """
  def resolve_recipients(owner_id, candidates) when is_list(candidates) do
    {ok, fail} = do_resolve(owner_id, candidates, MapSet.new(), MapSet.new(), MapSet.new())
    {MapSet.to_list(ok), MapSet.to_list(fail)}
  end

  defp do_resolve(_owner_id, [], ok, fail, _seen_lists), do: {ok, fail}

  defp do_resolve(owner_id, [candidate | rest], ok, fail, seen_lists) do
    candidate = String.trim(to_string(candidate))

    cond do
      candidate == "" ->
        do_resolve(owner_id, rest, ok, fail, seen_lists)

      target = nickname_to_user_id(owner_id, candidate) ->
        do_resolve(owner_id, rest, MapSet.put(ok, target), fail, seen_lists)

      # Cycle guard: a mailing-list name already expanded once on this
      # resolution is skipped the second time. Member nicknames normally
      # resolve as nicknames (step 1) so lists don't recur, but this keeps
      # a pathological name collision from looping unbounded.
      MapSet.member?(seen_lists, candidate) ->
        do_resolve(owner_id, rest, ok, fail, seen_lists)

      member_nicknames = list_to_member_nicknames(owner_id, candidate) ->
        do_resolve(owner_id, member_nicknames ++ rest, ok, fail, MapSet.put(seen_lists, candidate))

      user_exists?(candidate) ->
        do_resolve(owner_id, rest, MapSet.put(ok, candidate), fail, seen_lists)

      true ->
        do_resolve(owner_id, rest, ok, MapSet.put(fail, candidate), seen_lists)
    end
  end

  defp user_exists?(id) do
    Repo.one(from(u in User, where: u.id == ^id, select: 1)) != nil
  end

  defp nickname_to_user_id(owner_id, nickname) do
    Repo.one(
      from(a in AddressBookEntry,
        where: a.owner_id == ^owner_id and a.nickname == ^nickname,
        select: a.target_user_id
      )
    )
  end

  defp list_to_member_nicknames(owner_id, list_name) do
    case Repo.one(
           from(l in MailingList,
             where: l.owner_id == ^owner_id and l.name == ^list_name,
             select: l.id
           )
         ) do
      nil ->
        nil

      list_id ->
        Repo.all(
          from(m in MailingListMember,
            join: a in AddressBookEntry,
            on: a.id == m.address_book_entry_id,
            where: m.mailing_list_id == ^list_id,
            select: a.nickname
          )
        )
    end
  end

  @doc "Get all address book entries for a user"
  def get_user_address_book(user_id) do
    AddressBookEntry
    |> where([e], e.owner_id == ^user_id)
    |> order_by([e], asc: e.nickname)
    |> preload(:target_user)
    |> Repo.all()
  end

  @doc "Get all mailing lists for a user"
  def get_user_mailing_lists(user_id) do
    MailingList
    |> where([l], l.owner_id == ^user_id)
    |> order_by([l], asc: l.list_number)
    |> preload(members: [:target_user])
    |> Repo.all()
  end

  @doc "Get members of a specific mailing list"
  def get_mailing_list_members(user_id, list_number) do
    MailingList
    |> where([l], l.owner_id == ^user_id and l.list_number == ^list_number)
    |> preload(members: [:target_user])
    |> Repo.one()
  end

  @doc "Add entry to address book"
  def add_address_book_entry(owner_id, target_user_id, nickname) do
    # Find next available entry number
    next_entry_number =
      AddressBookEntry
      |> where([e], e.owner_id == ^owner_id)
      |> select([e], max(e.entry_number))
      |> Repo.one()
      |> Kernel.||(0)
      |> Kernel.+(1)

    %AddressBookEntry{}
    |> AddressBookEntry.changeset(%{
      owner_id: owner_id,
      target_user_id: target_user_id,
      nickname: nickname,
      entry_number: next_entry_number
    })
    |> Repo.insert()
  end

  @doc "Add members to mailing list"
  def add_members_to_list(user_id, list_number, entry_numbers) do
    list =
      MailingList
      |> where([l], l.owner_id == ^user_id and l.list_number == ^list_number)
      |> Repo.one()

    if list do
      entries =
        AddressBookEntry
        |> where([e], e.owner_id == ^user_id and e.entry_number in ^entry_numbers)
        |> Repo.all()

      Enum.each(entries, fn entry ->
        %MailingListMember{}
        |> MailingListMember.changeset(%{
          mailing_list_id: list.id,
          address_book_entry_id: entry.id
        })
        |> Repo.insert(on_conflict: :nothing)
      end)

      :ok
    else
      {:error, :list_not_found}
    end
  end

  @doc "Remove members from mailing list"
  def remove_members_from_list(user_id, list_number, entry_numbers) do
    list =
      MailingList
      |> where([l], l.owner_id == ^user_id and l.list_number == ^list_number)
      |> Repo.one()

    if list do
      entry_ids =
        AddressBookEntry
        |> where([e], e.owner_id == ^user_id and e.entry_number in ^entry_numbers)
        |> select([e], e.id)
        |> Repo.all()

      {_count, _} =
        MailingListMember
        |> where([m], m.mailing_list_id == ^list.id and m.address_book_entry_id in ^entry_ids)
        |> Repo.delete_all()

      :ok
    else
      {:error, :list_not_found}
    end
  end

  @doc "Get a single address book entry by entry number"
  def get_address_book_entry(user_id, entry_number) do
    AddressBookEntry
    |> where([e], e.owner_id == ^user_id and e.entry_number == ^entry_number)
    |> preload(:target_user)
    |> Repo.one()
  end

  @doc "Get address book entries NOT in a specific mailing list"
  def get_address_book_not_in_list(user_id, list_number) do
    list =
      MailingList
      |> where([l], l.owner_id == ^user_id and l.list_number == ^list_number)
      |> preload(:members)
      |> Repo.one()

    if list do
      member_entry_ids = Enum.map(list.members, & &1.id)

      AddressBookEntry
      |> where([e], e.owner_id == ^user_id)
      |> where([e], e.id not in ^member_entry_ids)
      |> order_by([e], asc: e.nickname)
      |> preload(:target_user)
      |> Repo.all()
    else
      get_user_address_book(user_id)
    end
  end

  @doc "Get all mailing lists that contain a specific address book entry"
  def get_lists_for_entry(user_id, entry_number) do
    entry = get_address_book_entry(user_id, entry_number)

    if entry do
      MailingList
      |> join(:inner, [l], m in MailingListMember, on: m.mailing_list_id == l.id)
      |> where([l, m], l.owner_id == ^user_id and m.address_book_entry_id == ^entry.id)
      |> order_by([l], asc: l.name)
      |> Repo.all()
    else
      []
    end
  end

  @doc "Create a new mailing list with initial members"
  def create_mailing_list(user_id, name, list_number, entry_numbers) do
    Repo.transaction(fn ->
      list_changeset =
        %MailingList{}
        |> MailingList.changeset(%{
          owner_id: user_id,
          name: name,
          list_number: list_number,
          max_members: get_max_members_per_list(user_id)
        })

      case Repo.insert(list_changeset) do
        {:ok, list} ->
          entries =
            AddressBookEntry
            |> where([e], e.owner_id == ^user_id and e.entry_number in ^entry_numbers)
            |> Repo.all()

          Enum.each(entries, fn entry ->
            %MailingListMember{}
            |> MailingListMember.changeset(%{
              mailing_list_id: list.id,
              address_book_entry_id: entry.id
            })
            |> Repo.insert!()
          end)

          list

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Delete a mailing list"
  def delete_mailing_list(user_id, list_number) do
    MailingList
    |> where([l], l.owner_id == ^user_id and l.list_number == ^list_number)
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      list ->
        case Repo.delete(list) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  @doc "Get maximum members allowed per list for a user. Could be configurable; default matches original Prodigy."
  def get_max_members_per_list(_user_id), do: 15

  @doc "Update address book entry (nickname or target user)"
  def update_address_book_entry(user_id, entry_number, attrs) do
    case get_address_book_entry(user_id, entry_number) do
      nil ->
        {:error, :not_found}

      entry ->
        update_attrs =
          attrs
          |> Map.take([:nickname, :target_user_id])
          |> Map.put(:owner_id, user_id)
          |> Map.put(:entry_number, entry_number)

        entry
        |> AddressBookEntry.changeset(update_attrs)
        |> Repo.update()
    end
  end

  @doc "Delete address book entry. Cascades through mailing_list_members."
  def delete_address_book_entry(user_id, entry_number) do
    case get_address_book_entry(user_id, entry_number) do
      nil -> {:error, :not_found}
      entry -> Repo.delete(entry)
    end
  end

  @doc "Get next available entry number for user's address book"
  def get_next_entry_number(user_id) do
    max_entry =
      AddressBookEntry
      |> where([e], e.owner_id == ^user_id)
      |> select([e], max(e.entry_number))
      |> Repo.one()

    case max_entry do
      nil ->
        1

      n when n < 50 ->
        n + 1

      _ ->
        # Find first gap in sequence
        used_numbers =
          AddressBookEntry
          |> where([e], e.owner_id == ^user_id)
          |> select([e], e.entry_number)
          |> order_by([e], asc: e.entry_number)
          |> Repo.all()

        Enum.find(1..50, fn n -> n not in used_numbers end)
    end
  end

  @doc "Check if user can create more mailing lists"
  def can_create_mailing_list?(user_id) do
    list_count =
      MailingList
      |> where([l], l.owner_id == ^user_id)
      |> Repo.aggregate(:count, :id)

    # Arbitrary limit, could be configurable
    list_count < 10
  end

  @doc "Get next available list number for user"
  def get_next_list_number(user_id) do
    max_list =
      MailingList
      |> where([l], l.owner_id == ^user_id)
      |> select([l], max(l.list_number))
      |> Repo.one()

    (max_list || 0) + 1
  end
end
