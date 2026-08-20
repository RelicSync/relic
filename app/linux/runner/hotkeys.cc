#include "hotkeys.h"

#include <X11/Xlib.h>
#include <gdk/gdkx.h>
#include <gtk/gtk.h>

#include <map>
#include <string>
#include <vector>

// Why Relic grabs keys itself instead of using a library:
//
// 1. hotkey_manager_linux 0.2.0 hands Flutter's physical keyCode straight to
//    gtk_accelerator_name() as though it were a GDK keyval, so Relic's summon
//    chord (Ctrl+Shift+Space) came out as "<Primary><Shift>KP_Space" — the
//    KEYPAD space — and never fired. It also ignores the bind result and
//    answers success unconditionally, so a refused grab looked like a working
//    hotkey and Relic's "these hotkeys failed" surface stayed empty.
//
// 2. keybinder-3.0 0.3.2 (the first replacement) grabs correctly but cannot
//    DISPATCH a Shift+printable chord. Its event filter asks GDK to translate
//    the event to a keysym, then subtracts the modifiers GDK reports as
//    "consumed" before comparing. Pressing Ctrl+Shift+Q consumes the Shift to
//    produce `Q`, so the event compares as Control alone and never equals the
//    binding's Control|Shift. Every Relic default except the summon chord is
//    Ctrl+Shift+<printable>, so exactly one hotkey worked. Space survived only
//    because Shift does not alter it.
//
// Both verified on Ubuntu 24.04/Xorg (2026-08-20); (2) was reproduced with a
// standalone keybinder program to rule out Flutter: <Control><Shift>space,
// <Control><Shift>F9, <Control><Alt>q and <Control><Shift>Left all fire,
// <Control><Shift>q does not.
//
// So: Dart builds the accelerator (platform/global_hotkeys.dart), we XGrabKey
// it on the root window, and the filter below matches the RAW keycode and
// modifier state — no keysym translation, nothing "consumed", layout changes
// cannot move the chord off the physical key the user chose. Same shape as
// clipboard_watch.cc and the macOS Swift bridges: change the Dart and the C++
// together.

static FlMethodChannel* g_channel = nullptr;

struct Binding {
  std::string id;
  guint modifiers;              // real X modifier bits, ignorables stripped
  std::vector<guint> keycodes;  // every keycode that produces the keyval
};

// accelerator -> binding, so the filter can name the chord for Dart and
// unregisterAll has something to walk.
static std::map<std::string, Binding>* g_bindings = nullptr;
static bool g_filter_installed = false;

// The modifiers that take part in matching. GDK_LOCK_MASK (CapsLock) and
// GDK_MOD2_MASK (NumLock) are deliberately absent: they are latched state the
// user is not "holding", so they are grabbed in every combination below and
// masked out of the comparison.
static const guint kRelevantMods = GDK_SHIFT_MASK | GDK_CONTROL_MASK |
                                   GDK_MOD1_MASK | GDK_MOD3_MASK |
                                   GDK_MOD4_MASK | GDK_MOD5_MASK;

// X grabs are exact-match on the modifier mask, so a chord has to be grabbed
// once per combination of the latched modifiers we want to ignore.
static const guint kIgnoredMods[] = {
    0,
    GDK_MOD2_MASK,
    GDK_LOCK_MASK,
    GDK_MOD2_MASK | GDK_LOCK_MASK,
};

static GdkWindow* root_window() {
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr || !GDK_IS_X11_DISPLAY(display)) {
    return nullptr;  // Wayland: Dart short-circuits before it gets here
  }
  return gdk_screen_get_root_window(gdk_display_get_default_screen(display));
}

static GdkFilterReturn filter_func(GdkXEvent* gdk_xevent,
                                   GdkEvent* event,
                                   gpointer user_data) {
  XEvent* xevent = reinterpret_cast<XEvent*>(gdk_xevent);
  if (xevent->type != KeyPress || g_channel == nullptr ||
      g_bindings == nullptr) {
    return GDK_FILTER_CONTINUE;
  }
  const guint keycode = xevent->xkey.keycode;
  const guint state = xevent->xkey.state & kRelevantMods;
  for (const auto& entry : *g_bindings) {
    const Binding& binding = entry.second;
    if (binding.modifiers != state) {
      continue;
    }
    bool hit = false;
    for (const guint candidate : binding.keycodes) {
      if (candidate == keycode) {
        hit = true;
        break;
      }
    }
    if (!hit) {
      continue;
    }
    if (g_getenv("RELIC_HOTKEY_DEBUG") != nullptr) {
      g_print("[relic-hotkeys] fired: %s\n", entry.first.c_str());
    }
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "id",
                             fl_value_new_string(binding.id.c_str()));
    fl_method_channel_invoke_method(g_channel, "onKeyDown", args, nullptr,
                                    nullptr, nullptr);
    return GDK_FILTER_REMOVE;  // it is our grab; nobody else should see it
  }
  return GDK_FILTER_CONTINUE;
}

// Fills the physical half of a binding. False means the accelerator does not
// name a key this keyboard can produce.
static bool resolve(const char* accelerator, Binding* out) {
  guint keyval = 0;
  GdkModifierType parsed = static_cast<GdkModifierType>(0);
  gtk_accelerator_parse(accelerator, &keyval, &parsed);
  if (keyval == 0) {
    return false;
  }
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) {
    return false;
  }
  GdkKeymap* keymap = gdk_keymap_get_for_display(display);

  // <Super>/<Meta> are virtual; the X event reports Mod4/Mod1. Map them down
  // so both sides of the comparison speak in real bits.
  GdkModifierType real = parsed;
  gdk_keymap_map_virtual_modifiers(keymap, &real);
  out->modifiers = static_cast<guint>(real) & kRelevantMods;

  GdkKeymapKey* keys = nullptr;
  gint n_keys = 0;
  if (!gdk_keymap_get_entries_for_keyval(keymap, keyval, &keys, &n_keys)) {
    return false;
  }
  for (gint i = 0; i < n_keys; i++) {
    // Group 0 only — Relic does not follow layout-group switches — and level 0,
    // because Shift belongs in the modifier mask rather than in a shifted
    // level. Reading level 1 here is how the KP_Space class of bug starts.
    if (keys[i].group != 0 || keys[i].level != 0) {
      continue;
    }
    out->keycodes.push_back(static_cast<guint>(keys[i].keycode));
  }
  g_free(keys);
  return !out->keycodes.empty();
}

// grab == false always succeeds as far as callers care; errors while ungrabbing
// mean the grab was already gone.
static bool grab(const Binding& binding, bool on) {
  GdkWindow* root = root_window();
  if (root == nullptr) {
    return false;
  }
  GdkDisplay* display = gdk_display_get_default();
  Display* xdisplay = GDK_DISPLAY_XDISPLAY(display);
  Window xroot = GDK_WINDOW_XID(root);
  gdk_x11_display_error_trap_push(display);
  for (const guint keycode : binding.keycodes) {
    for (const guint extra : kIgnoredMods) {
      if (on) {
        XGrabKey(xdisplay, static_cast<int>(keycode), binding.modifiers | extra,
                 xroot, False, GrabModeAsync, GrabModeAsync);
      } else {
        XUngrabKey(xdisplay, static_cast<int>(keycode),
                   binding.modifiers | extra, xroot);
      }
    }
  }
  gdk_display_flush(display);
  // BadAccess here means another client already holds the grab. XGrabKey
  // reports it asynchronously, which is why the trap has to sync (pop does).
  return gdk_x11_display_error_trap_pop(display) == 0;
}

static void drop(const std::string& accelerator) {
  auto it = g_bindings->find(accelerator);
  if (it == g_bindings->end()) {
    return;
  }
  grab(it->second, false);
  g_bindings->erase(it);
}

// "ok" | "unmappable" | "taken" | "unavailable". Anything thrown or missing on
// the Dart side becomes HotkeyFailure.unavailable there, so this only names
// real outcomes.
static const char* bind_one(const char* id, const char* accelerator) {
  if (root_window() == nullptr) {
    return "unavailable";
  }
  Binding binding;
  binding.id = id;
  if (!resolve(accelerator, &binding)) {
    return "unmappable";
  }
  drop(std::string(accelerator));  // rebinding would otherwise leak the grab
  if (!grab(binding, true)) {
    grab(binding, false);  // undo whatever landed before the refusal
    return "taken";
  }
  (*g_bindings)[std::string(accelerator)] = binding;
  if (g_getenv("RELIC_HOTKEY_DEBUG") != nullptr) {
    g_print("[relic-hotkeys] bound %s -> %s\n", accelerator, id);
  }
  return "ok";
}

static void unbind_all() {
  if (g_bindings == nullptr) {
    return;
  }
  for (const auto& entry : *g_bindings) {
    grab(entry.second, false);
  }
  g_bindings->clear();
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "register") == 0) {
    FlValue* id_v = fl_value_lookup_string(args, "id");
    FlValue* acc_v = fl_value_lookup_string(args, "accelerator");
    const char* result = "unmappable";
    if (id_v != nullptr && acc_v != nullptr &&
        fl_value_get_type(id_v) == FL_VALUE_TYPE_STRING &&
        fl_value_get_type(acc_v) == FL_VALUE_TYPE_STRING) {
      result = bind_one(fl_value_get_string(id_v), fl_value_get_string(acc_v));
    }
    g_autoptr(FlValue) out = fl_value_new_string(result);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(out));
  } else if (g_strcmp0(method, "unregisterAll") == 0) {
    unbind_all();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

void relic_hotkeys_register(FlBinaryMessenger* messenger) {
  if (g_channel != nullptr) {
    return;
  }
  g_bindings = new std::map<std::string, Binding>();
  // Grabbed keys are delivered to the grab window, so the filter goes on the
  // root. On Wayland there is no X11 display and bind_one answers
  // "unavailable" — Dart short-circuits before that in practice.
  GdkWindow* root = root_window();
  if (root != nullptr && !g_filter_installed) {
    gdk_window_add_filter(root, filter_func, nullptr);
    g_filter_installed = true;
  }

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(messenger, "relic/hotkeys",
                                    FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, method_call_cb, nullptr,
                                            nullptr);
}
