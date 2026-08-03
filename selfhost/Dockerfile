# Relic self-host image. Build from the REPO ROOT (it needs both worker/ and
# selfhost/):
#   docker build -f selfhost/Dockerfile -t relic-selfhost .
#
# Deps are installed at /app so node_modules resolves for both /app/worker and
# /app/selfhost (the server imports the unchanged worker, which imports `jose`).
FROM node:22-bookworm-slim

# better-sqlite3 ships prebuilt binaries for common platforms; the build toolchain
# is a fallback for anything without a prebuild (e.g. some arm variants).
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install once, at the root, from the selfhost manifest.
COPY selfhost/package.json ./package.json
RUN npm install --no-audit --no-fund

# App sources: the unchanged worker + the self-host layer. Copy only source
# paths (never node_modules or a local data dir) so a host build for a different
# OS/arch can't leak in a mismatched native better-sqlite3.
COPY worker/src ./worker/src
COPY worker/schema.sql ./worker/schema.sql
COPY selfhost/src ./selfhost/src

ENV RELIC_DATA_DIR=/data
ENV PORT=8787
EXPOSE 8787
VOLUME ["/data"]

# All data (SQLite + blobs) lives in the mounted /data volume.
CMD ["npx", "tsx", "selfhost/src/server.ts"]
