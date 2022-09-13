import Config

if System.get_env("RELEASE_MODE") do
  config :core, Prodigy.Core.Data.Repo,
         database: System.fetch_env!("DB_NAME"),
         username: System.fetch_env!("DB_USER"),
         password: System.fetch_env!("DB_PASS"),
         hostname: System.fetch_env!("DB_HOST"),
         show_sensitive_data_on_connection_error: true
end

