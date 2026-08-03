# Relic self-host

Run your own Relic sync server. Your clipboard history syncs across your devices
through a server **you** control, with no account and no company in the middle.

This runs the *exact same* server code as Relic Cloud (`worker/src`, imported
unchanged), just backed by a local SQLite file and local-disk storage instead of
Cloudflare. It is **zero-knowledge**: the server only ever stores ciphertext. Your
data is encrypted on your devices with XChaCha20-Poly1305 and a key derived from
your passphrase with Argon2id. The server never sees your passphrase or your key.

## Quick start (one command)

Pull the prebuilt multi-arch image (works on x86 and ARM, including Raspberry Pi
and most NAS boxes). All data lives in the named volume, which is the only thing
to back up.

```sh
docker run -d --name relic \
  -p 8787:8787 \
  -v relic-data:/data \
  ghcr.io/relicsync/relic-selfhost
```

Prefer Compose? A ready-to-use [`docker-compose.yml`](./docker-compose.yml) is in
this folder: `docker compose up -d`.

To build from source instead of pulling (needs both `worker/` and `selfhost/`, so
run it from the repo root):

```sh
docker build -f selfhost/Dockerfile -t relic-selfhost .
docker run -d --name relic -p 8787:8787 -v relic-data:/data relic-selfhost
```

### Then connect the app

- **Desktop:** Settings → **Connect… → Your own server**, enter
  `http://<your-host>:8787` and a passphrase. The first device to connect creates
  the vault and shows you a **recovery kit** (save it — the passphrase is the only
  way in).
- **Phone:** Add this device → **Use your own server**. Type the address, or tap
  **Scan QR** and point it at the QR shown on the desktop under
  Settings → Add a device → Show QR.

Enter the same passphrase on every device and they all sync to the same encrypted
vault. On a home network the phone reaches the server directly; to sync from
outside your network, expose it with a tunnel (e.g. Tailscale) or a VPS.

## How enrollment works (account-less, passphrase-only)

There are no accounts and no server-side passphrase to configure. From the
passphrase you type in the app, the client derives two separate values:

- an **auth token** — sent to the server so it recognizes your devices
- a **vault key** — used only on-device to encrypt/decrypt; **never sent**

The server stores only `sha256(auth token)`. The **first** device to connect
claims the instance (trust-on-first-use); every later device that presents the
same passphrase is recognized automatically. A wrong passphrase is rejected. To
add a device you only need the server URL and the passphrase — no account and no
pairing dance. (For convenience the app can also show a QR carrying just the
server address, so a phone can scan instead of typing an IP; the passphrase is
never in the QR.)

## Configuration

All optional; sensible defaults for a single-user/household instance.

| Env var | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8787` | Port to listen on. |
| `RELIC_DATA_DIR` | `/data` | Where SQLite (`relic.db`) and blobs (`blobs/`) live. |
| `RELIC_ENROLL_SECRET` | _(unset)_ | If set, the **first** enrollment must also present this, so nobody can claim a fresh instance before you do. |
| `RELIC_APP_BASE_URL` | `http://localhost` | Only used to build absolute links; irrelevant to sync. |

## Backups

Everything is under `RELIC_DATA_DIR` (the `relic-data` volume). Snapshot or copy
that directory and you have a complete backup. There is no external database.
Because the vault is end-to-end encrypted, a stolen backup is useless without the
passphrase.

## Resetting the passphrase

Enrollment is trust-on-first-use, so to change the claiming passphrase, clear the
token and re-enroll:

```sh
docker exec relic sh -c 'sqlite3 /data/relic.db "DELETE FROM tokens;"'
```

(Your encrypted items stay put; the next device to connect re-claims the
instance. Only devices using the new passphrase will be able to decrypt items
created under it, so change the passphrase in the app on every device.)

## Scope and limits

This zero-dependency build uses SQLite plus local-disk storage, which is ideal
for one person or a household. It is not sized for hundreds of concurrent users;
that is the job of the (optional, future) `docker-compose` stack with Postgres
and S3-compatible object storage. The application code is identical either way —
only the storage adapters differ.

## Development

```sh
cd selfhost
npm install
npm run smoke   # in-process test: round-trips the full sync data plane
npm start       # runs the HTTP server (uses ./data by default)
```

The self-host layer is intentionally thin:

- `src/adapters/d1.ts` — a `D1Database`-shaped shim over `better-sqlite3`
- `src/adapters/r2.ts` — an `R2Bucket`-shaped shim over the local filesystem
- `src/adapters/kv.ts` — a `KVNamespace`-shaped shim over a SQLite table
- `src/adapters/env.ts` — assembles the `Env` the worker expects
- `src/enroll.ts` — the account-less `POST /enroll` endpoint
- `src/server.ts` — bridges `node:http` to the unchanged worker `fetch()` handler

Everything else — the sync protocol, blob handling, tombstones, device registry —
is the same code that runs Relic Cloud, so the two can never drift.
