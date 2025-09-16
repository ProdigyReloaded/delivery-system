defmodule Prodigy.Core.Data.Repo.Migrations.CreateCmcErrorTable do
  use Ecto.Migration

  def change do
    create table(:cmc_error) do
      add :session_id, references(:session, on_delete: :nothing), null: false
      add :user_id, :string, null: false
      add :system_origin, :string
      add :msg_origin, :string
      add :unit_id, :string
      add :error_code, :string
      add :severity_level, :string
      add :error_threshold, :string
      add :error_date, :string
      add :error_time, :string
      add :api_event, :string
      add :mem_to_start, :string
      add :dos_version, :string
      add :rs_version, :string
      add :window_id, :string
      add :window_last, :string
      add :selected_id, :string
      add :selected_last, :string
      add :base_id, :string
      add :base_last, :string
      add :keyword, :string
      add :raw_payload, :binary

      timestamps(updated_at: false)
    end

    create index(:cmc_error, [:session_id])
    create index(:cmc_error, [:user_id])
    create index(:cmc_error, [:error_code])
    create index(:cmc_error, [:inserted_at])
  end
end
