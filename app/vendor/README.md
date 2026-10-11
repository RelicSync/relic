# Vendored packages

## flutter_onnxruntime 1.8.5

The pub.dev package, MIT (see its LICENSE), with one change: the `macos/`
folder and the `macos:` entry under `flutter.plugin.platforms` are removed.
The example app, docs and logo are left out.

Why: the plugin's macOS Swift package declares a macOS 14 floor, and Relic's
Mac build targets macOS 11. Only the phone uses this plugin (the query
encoder in `lib/mobile.dart`); the desktop embeds through relic-sift. With
the pub copy, `flutter build macos` fails:

    error: The package product 'flutter-onnxruntime' requires minimum platform
    version 14.0 for the macOS platform, but this target supports 11.0

`app/pubspec.yaml` points `dependency_overrides` here. Android, iOS, Linux
and Windows build the same native code they would from pub.

To upgrade: copy the new version from `~/.pub-cache/hosted/pub.dev/` over
this folder, remove `macos/` and the `macos:` platform entry again, and bump
the constraint in `app/pubspec.yaml`.
