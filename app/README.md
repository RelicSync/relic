# Relic Flutter Desktop

`app/` is the active Relic desktop client. It captures clipboard text, images,
and files into the local SQLite store, syncs encrypted relic envelopes with the
Worker, and launches the tray/hotkey popup on Windows.

The older Rust desktop client in `../relic-app/` is kept as a reference for
native Windows behavior and legacy tests, not as the product client.

## Local security posture

- Sync secrets are stored in Windows Credential Manager. On first reconnect the
  app migrates the legacy `%APPDATA%\relic\key.bin` master-key cache and deletes
  that raw key file.
- Clipboard watcher captures skip Windows exclusion formats used by password
  managers and other sensitive apps.
- Outbound sync uses a durable SQLite pending-op queue, so offline captures,
  edits, and deletes retry after restart.

## Development

```powershell
flutter pub get
flutter test
flutter run -d windows
```

Live Worker sync tests are opt-in because they need credentials:

```powershell
$env:RELIC_URL = "https://..."
$env:RELIC_SYNC_TOKEN = "..."
$env:RELIC_SYNC_PASS = "..."
flutter test test/sync_test.dart
```
