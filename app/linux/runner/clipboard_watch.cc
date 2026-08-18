#include "clipboard_watch.h"

#include <gtk/gtk.h>

// Why this bridge exists instead of the clipboard_watcher plugin:
//
// clipboard_watcher 0.3.0's Linux implementation watches GDK_SELECTION_PRIMARY
// — the X11 select-to-copy buffer — not GDK_SELECTION_CLIPBOARD. On Linux that
// is wrong twice over: a Ctrl+C never notifies us at all, and merely SELECTING
// text in any app would fire a capture. Verified on Ubuntu 24.04/Xorg
// (2026-08-18) before this was written. Relic therefore skips that plugin on
// Linux (desktop.dart) and uses this channel, which is the direct analogue of
// the macOS bridges under macos/Runner/Bridge — change the two together.
//
// The Dart side does the rest: it reads the clipboard through the same format
// ladder as every platform and applies the pause, privacy-marker, blocklist
// and echo guards, so this only has to say "something changed".

static FlMethodChannel* g_channel = nullptr;

static void handle_owner_change(GtkClipboard* clipboard,
                                GdkEvent* event,
                                gpointer user_data) {
  if (g_channel == nullptr) {
    return;
  }
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_method_channel_invoke_method(g_channel, "onClipboardChanged", args,
                                  nullptr, nullptr, nullptr);
}

// Nothing to answer: Dart only listens. Responding "not implemented" to
// anything else keeps the channel honest if a future call is added.
static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(method_call, response, nullptr);
}

void relic_clipboard_watch_register(FlBinaryMessenger* messenger) {
  if (g_channel != nullptr) {
    return;
  }
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(messenger, "relic/clipboard_watch",
                                    FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, method_call_cb, nullptr,
                                            nullptr);

  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  g_signal_connect(clipboard, "owner-change", G_CALLBACK(handle_owner_change),
                   nullptr);
}
