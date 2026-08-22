#include "desktop_env.h"

#include <gio/gio.h>

// Does this desktop actually show tray icons?
//
// Relic's whole quit-to-tray story assumes something is there to quit to. On
// Windows and macOS that is guaranteed; on Linux it is not. Stock GNOME has
// shipped no system tray since 3.26 — tray_manager talks to libayatana, which
// publishes a StatusNotifierItem over D-Bus, and with no watcher registered the
// icon simply goes nowhere. tray_manager reports success either way, so the app
// cheerfully hid itself into a tray that does not exist and the only way back
// was a hotkey the user had not been told about.
//
// The honest test is the one the spec defines: is anybody owning the
// StatusNotifierWatcher name on the session bus? Ubuntu answers yes (it ships
// the AppIndicator extension), Fedora's stock GNOME answers no, KDE and XFCE
// answer yes. Both names are checked because KDE registers the original
// org.kde.* name and the freedesktop-namespaced one is what newer hosts use.
//
// This is a fact about the desktop, not about Relic's settings — what the user
// is TOLD changes (the tray hint promises the hotkey instead of an icon), never
// whether the icon is attempted. A wrong answer here must not remove a tray
// that would have worked, so anything unexpected reads as "yes, there is one",
// leaving the copy exactly as it was before this existed.

static const char* kWatcherNames[] = {"org.kde.StatusNotifierWatcher",
                                      "org.freedesktop.StatusNotifierWatcher"};

static bool name_has_owner(GDBusConnection* bus, const char* name) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner", g_variant_new("(s)", name),
      G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, &error);
  if (reply == nullptr) {
    return false;
  }
  gboolean owned = FALSE;
  g_variant_get(reply, "(b)", &owned);
  return owned == TRUE;
}

static bool has_tray_host() {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus == nullptr) {
    return true;  // no session bus to ask: assume a tray, change nothing
  }
  for (const char* name : kWatcherNames) {
    if (name_has_owner(bus, name)) {
      return true;
    }
  }
  return false;
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(method_call), "hasTrayHost") == 0) {
    g_autoptr(FlValue) out = fl_value_new_bool(has_tray_host());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(out));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

void relic_desktop_env_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "relic/desktop_env", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
}
