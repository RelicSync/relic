#include "window_focus.h"

#include <X11/Xlib.h>
#include <gdk/gdkx.h>

#include "hotkeys.h"

// Why summoning the picker needs more than show() + focus():
//
// Modern window managers refuse focus requests they cannot attribute to the
// user, so that a background app cannot yank the keyboard out from under
// whatever you are typing in. Mutter's answer to a refused request is to raise
// the window and set _NET_WM_STATE_DEMANDS_ATTENTION — which is exactly what
// Relic got: the picker appeared, on top, and every keystroke kept going to
// the terminal behind it. Verified on Ubuntu 24.04/Xorg (2026-08-20); it does
// NOT reproduce when the desktop itself holds focus, which is how it hid
// during the first pass of this work.
//
// The cure is to say WHEN the user asked. X focus requests carry a server
// timestamp, and the only moment Relic has one first-hand is the hotkey press,
// which hotkeys.cc keeps for us. Setting it as the window's _NET_WM_USER_TIME
// and presenting with that same stamp turns the request from unattributable
// into "the user pressed a key at time T", which mutter honours.
//
// Deliberately NOT source-indication 2 (the "pager" escape hatch wmctrl uses),
// which window managers grant unconditionally. Relic has a real user event to
// point at, so it should point at it; an app that lies about being a pager is
// how focus-stealing prevention stops meaning anything.

static FlMethodChannel* g_channel = nullptr;
static GtkWindow* g_window = nullptr;

// True when the keyboard was actually claimed; false means the caller should
// keep whatever window_manager's focus() managed on its own.
static bool claim_focus() {
  if (g_window == nullptr) {
    return false;
  }
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(g_window));
  if (gdk_window == nullptr || !GDK_IS_X11_WINDOW(gdk_window)) {
    return false;  // Wayland, or not realized yet
  }
  guint32 when = relic_hotkeys_last_event_time();
  if (when == 0) {
    // Summoned from the tray rather than a hotkey: no press to point at, so
    // ask the server for "now", which is still an honest timestamp.
    when = gdk_x11_get_server_time(gdk_window);
  }
  gdk_x11_window_set_user_time(gdk_window, when);
  gtk_window_present_with_time(g_window, when);
  return true;
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(method_call), "claimFocus") == 0) {
    g_autoptr(FlValue) out = fl_value_new_bool(claim_focus());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(out));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

void relic_window_focus_register(FlBinaryMessenger* messenger,
                                 GtkWindow* window) {
  if (g_channel != nullptr) {
    return;
  }
  g_window = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(messenger, "relic/window_focus",
                                    FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, method_call_cb, nullptr,
                                            nullptr);
}
