# Stage 1: Build Stage
FROM hexpm/elixir:1.19.4-erlang-27.3.4.6-alpine-3.21.5 AS builder

# Install build dependencies
RUN apk add --no-cache \
    git \
    build-base \
    sqlite \
    sqlite-dev

# Set working directory
WORKDIR /app

# Set build environment
ENV MIX_ENV=prod

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./
COPY config config
COPY apps/vfs/mix.exs ./apps/vfs/
COPY apps/sync_engine/mix.exs ./apps/sync_engine/
COPY apps/grpc_server/mix.exs ./apps/grpc_server/

# Install dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application code
COPY apps apps

# Compile the project
RUN mix compile

# Build release
RUN mix release

# Stage 2: Runtime Stage
FROM alpine:3.21.5

# Install runtime dependencies
RUN apk add --no-cache \
    openssl \
    ncurses-libs \
    libstdc++ \
    sqlite \
    bash

# Create app user
RUN addgroup -g 1000 app && \
    adduser -D -u 1000 -G app app

# Set working directory
WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=app:app /app/_build/prod/rel/debrid_stream ./

# Copy entrypoint script
COPY --chown=app:app entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

# Create data directory for SQLite database
RUN mkdir -p /app/data && chown -R app:app /app/data

# Set environment variables
ENV HOME=/app
ENV MIX_ENV=prod
ENV RELEASE_COOKIE=change_me_in_production
ENV DATABASE_PATH=/app/data/debrid_stream_prod.db

# Switch to app user
USER app

# Expose gRPC port (default 50051, configurable via GRPC_PORT)
EXPOSE 50051

# Health check using the built-in health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD /app/bin/debrid_stream rpc "SyncEngine.HealthCheck.ping()" || exit 1

# Use entrypoint script
ENTRYPOINT ["/app/entrypoint.sh"]

# Default command
CMD ["/app/bin/debrid_stream", "start"]
