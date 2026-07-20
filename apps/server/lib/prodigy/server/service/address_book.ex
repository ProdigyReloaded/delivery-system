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

defmodule Prodigy.Server.Service.AddressBook do
  @behaviour Prodigy.Server.Service
  @moduledoc """
  DIA wire handler for the Personal Address Book + Mailing List features.

  Sub-codes under the outer `0xD` opcode:

    * 0x0F - pre-screen notification (no-op ack)
    * 0x01 - list entries
    * 0x02 - get a specific entry (address card)
    * 0x03 - add an entry
    * 0x04 - update an entry
    * 0x05 - delete entries (batch by entry number)
    * 0x06 - list mailing lists
    * 0x07 - get members of a mailing list
    * 0x08 - list address book entries NOT in a given mailing list (for add-members flow)
    * 0x09 - add members to a mailing list
    * 0x0A - remove members from a mailing list
    * 0x0B - list address book entries for the create-mailing-list flow
    * 0x0C - create a new mailing list (name + members)
    * 0x0D - delete mailing list(s) (batch)

  All DB-side logic lives in `Prodigy.Core.MessagingLists`; this module
  is pure decoding / response framing.
  """

  # TODO: known gaps when this work was last paused on the messaging branch -
  #   - confirm window for adding address book entries (MSZA011X.WND)
  #   - field post-processor on the entry page (advance cursor, uppercase user id)
  #   - mailing list add/delete sends the wrong list id (check the TBOL that emits
  #     the 0xD message)
  #   - button set on the mailing list screens
  #   - locate on the mailing list and address book

  require Logger

  alias Prodigy.Core.Data.Repo
  alias Prodigy.Core.Data.Service.User
  alias Prodigy.Core.MessagingLists
  alias Prodigy.Server.Context
  alias Prodigy.Server.Protocol.Dia.Packet, as: DiaPacket
  alias Prodigy.Server.Protocol.Dia.Packet.Fm0

  def handle(%Fm0{payload: <<0xD, payload::binary>>} = request, %Context{} = context) do
    user_id = context.user.id

    response =
      case payload do
        # Pre-address-book screen notification
        <<0xF>> ->
          :ok

        # Get address book entries
        <<0x1>> ->
          entries = MessagingLists.get_user_address_book(user_id)
          build_address_book_response(entries)

        # Get a specific address book entry (address card)
        <<0x2, entry_no::16-big>> ->
          case MessagingLists.get_address_book_entry(user_id, entry_no) do
            nil -> {:error, :not_found}
            entry -> build_address_card_response(entry)
          end

        # Add entry to address book
        <<0x3, user_id_str::binary-size(7), nickname_len::16-big,
          nickname::binary-size(nickname_len), 0x0, 0x0, _entry_no::16-big>> ->
          target_user_id = String.trim(user_id_str)

          case MessagingLists.add_address_book_entry(user_id, target_user_id, nickname) do
            {:ok, _entry} ->
              Logger.info("Added addressbook entry for #{nickname} -> #{target_user_id}")
              {:ok, <<0>>}

            {:error, changeset} ->
              Logger.error("Failed to add entry: #{inspect(changeset.errors)}")
              # Duplicate / validation
              {:ok, <<0x09>>}
          end

        # Update/modify address book entry
        <<0x04, entry_no::16-big, new_user_id::binary-size(7), nickname_len::16-big,
          new_nickname::binary-size(nickname_len)>> ->
          new_target_id = String.trim(new_user_id)

          case Repo.get(User, new_target_id) do
            nil ->
              {:ok, <<0x09>>}

            _target_user ->
              case MessagingLists.update_address_book_entry(user_id, entry_no, %{
                     target_user_id: new_target_id,
                     nickname: new_nickname
                   }) do
                {:ok, _entry} ->
                  Logger.info("Updated entry #{entry_no}: #{new_nickname} -> #{new_target_id}")
                  {:ok, <<0x00>>}

                {:error, :not_found} ->
                  Logger.error("Entry #{entry_no} not found for user #{user_id}")
                  {:ok, <<0x0B>>}

                {:error, changeset} ->
                  if Keyword.has_key?(changeset.errors, :nickname) do
                    Logger.error("Duplicate nickname: #{new_nickname}")
                    {:ok, <<0x0A>>}
                  else
                    Logger.error("Failed to update entry: #{inspect(changeset.errors)}")
                    {:ok, <<0x01>>}
                  end
              end
          end

        # Delete address book entries (batch)
        <<0x05, count::16-big, entry_ids::binary>> ->
          entry_numbers = parse_entry_numbers(entry_ids, count)

          deleted_count =
            Enum.reduce(entry_numbers, 0, fn entry_num, acc ->
              case MessagingLists.delete_address_book_entry(user_id, entry_num) do
                {:ok, _} -> acc + 1
                {:error, _} -> acc
              end
            end)

          if deleted_count > 0 do
            Logger.info("Deleted #{deleted_count} address book entries for user #{user_id}")
            {:ok, <<0x00>>}
          else
            Logger.error("Failed to delete any address book entries")
            {:ok, <<0x01>>}
          end

        # Get mailing lists
        <<0x6>> ->
          lists = MessagingLists.get_user_mailing_lists(user_id)
          max_members_per_list = MessagingLists.get_max_members_per_list(user_id)
          build_mailing_lists_response(lists, max_members_per_list)

        # Get members of a specific mailing list
        <<0x07, list_number::16-big>> ->
          updated_context = Map.put(context, :current_list_number, list_number)
          list = MessagingLists.get_mailing_list_members(user_id, list_number)
          max_members = MessagingLists.get_max_members_per_list(user_id)
          response = build_list_members_response(list, max_members)
          {:ok, response, updated_context}

        # Begin add-members-to-list flow (return non-members)
        <<0x8>> ->
          list_number = Map.get(context, :current_list_number)
          entries = MessagingLists.get_address_book_not_in_list(user_id, list_number)
          build_address_book_response(entries)

        # Add members to a list
        <<0x9, list_number::16-big, count::16-big, member_ids::binary>> ->
          entry_numbers = parse_entry_numbers(member_ids, count)

          case MessagingLists.add_members_to_list(user_id, list_number, entry_numbers) do
            :ok ->
              Logger.info("Added #{count} members to list #{list_number}")
              {:ok, <<0>>}

            {:error, reason} ->
              Logger.error("Failed to add members: #{inspect(reason)}")
              {:ok, <<0x01>>}
          end

        # Remove members from list
        <<0xA, list_number::16-big, count::16-big, member_ids::binary>> ->
          entry_numbers = parse_entry_numbers(member_ids, count)

          case MessagingLists.remove_members_from_list(user_id, list_number, entry_numbers) do
            :ok ->
              Logger.info("Removed #{count} members from list #{list_number}")
              {:ok, <<0>>}

            {:error, reason} ->
              Logger.error("Failed to remove members: #{inspect(reason)}")
              {:ok, <<0x01>>}
          end

        # Start mailing-list creation - return all address book entries
        <<0xB>> ->
          entries = MessagingLists.get_user_address_book(user_id)
          build_address_book_response(entries)

        # Create new mailing list
        <<0xC, name_len::16-big, list_name::binary-size(name_len), list_num::16-big,
          member_count::16-big, members::binary>> ->
          entry_numbers = parse_entry_numbers(members, member_count)

          case MessagingLists.create_mailing_list(user_id, list_name, list_num, entry_numbers) do
            {:ok, _list} ->
              Logger.info("Created list #{list_name} with #{member_count} members")
              :ok

            {:error, changeset} ->
              Logger.error("Failed to create list: #{inspect(changeset.errors)}")
              # Required for client compliance: MSZA028X.src SENDs 0x0d0c with
              # NO matching RECEIVE, so the client is not waiting for a reply.
              # Sending ANY response here (success OR error code) trips the
              # client's OMCM 10 "out of sequence" fault. We therefore return
              # `:ok` (no wire response) even on validation failure - matching
              # the success path - because staying protocol-compliant outranks
              # surfacing the error. Known consequence: on failure the client
              # locally believes the list was created until its next refresh
              # reconciles against the server. If server-side rejection ever
              # needs to reach the user, it has to ride a later client-
              # initiated RECEIVE (e.g. the next list-fetch), not this SEND.
              :ok
          end

        # Delete mailing list(s)
        <<0xD, count::16-big, list_ids::binary>> ->
          list_numbers = parse_entry_numbers(list_ids, count)
          Enum.each(list_numbers, &MessagingLists.delete_mailing_list(user_id, &1))
          Logger.info("Deleted #{count} list(s)")
          :ok

        _ ->
          Logger.warning("Unhandled addressbook request: #{inspect(payload, base: :hex)}")
          {:ok, <<>>}
      end

    case response do
      {:ok, payload} ->
        {:ok, context, DiaPacket.encode(Fm0.make_response(payload, request))}

      {:ok, response_data, updated_context} ->
        {:ok, updated_context, DiaPacket.encode(Fm0.make_response(response_data, request))}

      {:error, :not_found} ->
        {:ok, context, DiaPacket.encode(Fm0.make_response(<<0x0B>>, request))}

      _ ->
        {:ok, context}
    end
  end

  # --- response framing -----------------------------------------------

  defp build_address_book_response(entries) do
    entry_count = length(entries)

    entry_data =
      for entry <- entries, into: <<>> do
        nickname_bin = entry.nickname
        nickname_len = byte_size(nickname_bin)
        <<nickname_len, nickname_bin::binary, entry.entry_number::16-big, 0>>
      end

    {:ok, <<0x01, entry_count, 0x00, 0x00, 0x00, entry_data::binary>>}
  end

  defp build_address_card_response(entry) do
    user = entry.target_user
    user_id = String.pad_trailing(user.id, 7)
    nickname_bin = entry.nickname
    nickname_len = byte_size(nickname_bin)

    lists = MessagingLists.get_lists_for_entry(entry.owner_id, entry.entry_number)
    list_count = length(lists)

    list_data =
      for list <- lists, into: <<>> do
        name_bin = list.name
        name_len = byte_size(name_bin)
        <<name_len::16-big, name_bin::binary>>
      end

    {:ok,
     <<user_id::binary-size(7), nickname_len::16-big, nickname_bin::binary, 0, 0,
       list_count::16-big, list_data::binary>>}
  end

  defp build_mailing_lists_response(lists, max_members) do
    list_count = length(lists)
    can_create = if list_count < 10, do: 0x01, else: 0x00

    list_data =
      for list <- lists, into: <<>> do
        name_bin = list.name
        name_len = byte_size(name_bin)
        member_count = length(list.members)
        <<name_len, name_bin::binary, member_count::16-big, list.list_number::16-big, 0>>
      end

    {:ok, <<max_members, list_count, can_create, 0x00, 0x00, list_data::binary>>}
  end

  defp build_list_members_response(nil, max_members),
    do: <<0, 0, 0, max_members, 0>>

  defp build_list_members_response(list, max_members) do
    members = list.members
    member_count = length(members)

    member_data =
      for entry <- members, into: <<>> do
        nickname_bin = entry.nickname
        nickname_len = byte_size(nickname_bin)
        <<nickname_len, nickname_bin::binary, entry.entry_number::16-big, 0>>
      end

    <<0, member_count, 0, max_members, 0, member_data::binary>>
  end

  defp parse_entry_numbers(binary, count), do: parse_entry_numbers(binary, count, [])
  defp parse_entry_numbers(_binary, 0, acc), do: Enum.reverse(acc)

  defp parse_entry_numbers(<<entry::16-big, rest::binary>>, count, acc),
    do: parse_entry_numbers(rest, count - 1, [entry | acc])
end
