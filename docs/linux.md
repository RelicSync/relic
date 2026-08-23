# Relic on Linux

x86_64, built for X11. This page is the honest version of what works, what does
not, and why.

## Install

Two downloads, same build:

| | |
|---|---|
| **Tarball** | <https://relic.space/download/linux> — extract anywhere, run `./relic_app` |
| **AppImage** | <https://relic.space/download/linux/appimage> — `chmod +x`, run |

The tarball is the default because an AppImage needs `libfuse2`, which Ubuntu
has not installed by default since 22.04. If the AppImage exits complaining
about FUSE, either `sudo apt install libfuse2t64` or run it with
`--appimage-extract-and-run`.

Nothing installs system-wide and there is no package manager step. On first run
Relic writes its own launcher entry and icon to `~/.local/share/applications/`
and registers itself for `relic://` links, so it shows up in your launcher like
anything else. Its vault lives in `$XDG_DATA_HOME/relic` (usually
`~/.local/share/relic`), never in `~/.config`.

Self-update works from the AppImage, which is one file and can be swapped by a
single atomic rename while running. An unpacked tarball has no equivalent
story, so it takes you to the download page instead.

## X11 and Wayland

Relic is an X11-first app and says so rather than degrading quietly.

**On X11** everything works: the global hotkey, summoning the window with the
keyboard, and pasting the item you picked back into the app you were using.
Relic owns the `XGrabKey` itself in `app/linux/runner/` instead of delegating
it, and it passes the hotkey's own X timestamp to the focus request, because
Mutter refuses a focus request that arrives without one.

**On Wayland** the compositor does not hand any application a global hotkey or
let it synthesise keystrokes, by design. Relic still runs, still captures
everything you copy, and still syncs. What it will not do is pretend: the
hotkey reports itself as unavailable instead of silently failing, and there is
no paste-back. Use your desktop's own shortcut settings to launch or focus
Relic if you want a key for it.

You can check which session you are in with:

```sh
echo $XDG_SESSION_TYPE
```

## The tray

Stock GNOME has not had a system tray since 3.26. Relic asks the session bus
whether anything actually owns `StatusNotifierWatcher` before it tells you
where to find it, so on plain GNOME it points you at your keyboard shortcut
instead of at a tray icon that is not there. Install the AppIndicator extension
and the tray icon appears; Relic notices.

## Run at login

Settings has a "run at login" switch. It writes a standard XDG autostart entry
to `~/.config/autostart/space.relic.app.desktop` with `--autostart`, so Relic
starts quietly in the background without opening a window.

If you run the AppImage, the entry points at `$APPIMAGE` rather than the
executable path the process sees. An AppImage is mounted at a fresh
`/tmp/.mount_XXXXXX` every run, so an entry written from the running path would
work until your next reboot and then silently stop.

## On-device AI

`sift`, the local model sidecar, ships beside the app in both artifacts,
together with `libonnxruntime.so`. Nothing is downloaded at install time and
nothing leaves your machine. If you build from source instead,
`sift models download` fetches the matching onnxruntime for `linux-x64` from
our mirror.

## Known gaps

- Only x86_64 today. No aarch64 build.
- No distro packages (deb, rpm, AUR, Flatpak). The tarball and AppImage are it.
- Multi-monitor placement follows the monitor your cursor is on; the logic is
  unit-tested but has not been exercised on a real two-head setup.
- Tested against GNOME on Xorg. KDE and XFCE should work, including their
  trays, but have not been verified.
