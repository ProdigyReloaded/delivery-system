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

import Config

if System.get_env("RELEASE_MODE") do
  config :core, Prodigy.Core.Data.Repo,
    database: System.fetch_env!("DB_NAME"),
    username: System.fetch_env!("DB_USER"),
    password: System.fetch_env!("DB_PASS"),
    hostname: System.fetch_env!("DB_HOST"),
    show_sensitive_data_on_connection_error: true
end
