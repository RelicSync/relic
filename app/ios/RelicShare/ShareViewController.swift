import receive_sharing_intent

/// Relic's iOS/iPadOS share target.
///
/// D5 invariant (docs/apple-port-2026-08.md §1, docs/apple-release-checklist.md
/// §5): this process is a *courier*, never a vault writer. Everything it does is
/// inherited from `RSIShareViewController`, which copies the shared payload into
/// the App Group container (`group.space.relic.app`), records a manifest in that
/// group's `UserDefaults`, and opens the host app with
/// `ShareMedia-space.relic.app:share`. It never reads or writes the vault cache,
/// the master key, or the passphrase — the app drains that queue on the next
/// foreground and does all sealing and upload in one process
/// (`_handleShared`/`_flushPending` in `lib/mobile.dart`).
///
/// Deliberately empty: any override here would be a second writer, which is
/// exactly the failure class D5 exists to prevent. `shouldAutoRedirect()` is
/// left at its default (`true`) so a share hands off to the app immediately
/// instead of asking the user to confirm in a compose sheet.
class ShareViewController: RSIShareViewController {
}
