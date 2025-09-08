defmodule Prodigy.Core.Data.Repo.Migrations.FixMessageIds do
  use Ecto.Migration

  def up do
    # Drop the existing composite primary key constraint
    drop constraint(:message, "message_pkey")

    # Remove the old primary key columns and add new id
    alter table(:message) do
      remove :index
      add :id, :bigserial, primary_key: true
    end
  end

  def down do
    # Reverse the changes
    alter table(:message) do
      remove :id
      add :index, :integer
      add :to_id_primary, :boolean  # We'll need to handle the composite key separately
    end

    # Recreate the composite primary key
    create constraint(:message, "message_pkey", primary_key: [:to_id, :index])
  end
end
