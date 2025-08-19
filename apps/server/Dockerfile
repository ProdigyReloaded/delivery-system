FROM elixir:1.13.4-otp-25-slim AS release_stage

RUN apt-get update
RUN apt-get install --yes build-essential inotify-tools postgresql-client
RUN mix local.hex --force
RUN mix local.rebar --force

COPY apps/core/mix.exs apps/core/mix.exs
COPY apps/server/mix.exs apps/server/mix.exs
COPY apps/pomsutil/mix.exs apps/pomsutil/mix.exs
COPY apps/podbutil/mix.exs apps/podbutil/mix.exs

COPY mix.exs mix.lock ./

ENV MIX_ENV=prod

RUN mix deps.get
RUN mix deps.compile

COPY apps/core apps/core
COPY apps/server apps/server
COPY apps/pomsutil apps/pomsutil
COPY apps/podbutil apps/podbutil

COPY config config

RUN mix release server

RUN cd apps/pomsutil && mix escript.build
RUN cd apps/podbutil && mix escript.build

FROM elixir:1.13.4-otp-25-slim AS run_stage

# Install git for cloning the objects repository
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

COPY --from=release_stage $HOME/_build .
COPY --from=release_stage $HOME/apps/pomsutil/pomsutil /usr/local/bin
COPY --from=release_stage $HOME/apps/podbutil/podbutil /usr/local/bin
CMD ["./prod/rel/server/bin/server", "start"]