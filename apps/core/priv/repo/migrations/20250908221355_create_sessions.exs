defmodule Prodigy.Core.Data.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:session) do
      add :user_id, references(:user, type: :string, on_delete: :nothing), null: false
      add :logon_timestamp, :utc_datetime, null: false
      add :logon_status, :integer, null: false  # 0=success, 1=enroll_other, 2=enroll_subscriber
      add :logoff_timestamp, :utc_datetime
      add :logoff_status, :integer  # 0=normal, 1=abnormal, 2=timeout, 3=forced
      add :rs_version, :string
      add :node, :string, null: false
      add :pid, :string, null: false
      add :source_address, :string
      add :source_port, :integer
      add :last_activity_at, :utc_datetime

      timestamps()
    end

    create index(:session, [:user_id])
    create index(:session, [:logoff_timestamp])
    create index(:session, [:node])

    # Add concurrency_limit to users
    alter table(:user) do
      add :concurrency_limit, :integer, default: 1
    end

    # Remove logged_on from users (or keep it temporarily for rollback safety)
    alter table(:user) do
      remove :logged_on
    end
  end
end
