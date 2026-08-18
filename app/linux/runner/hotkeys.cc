#include "hotkeys.h"

#include <gtk/gtk.h>
#include <keybinder.h>

#include <map>
#include <string>

// Why this bridge exists instead of the hotkey_manager plugin:
//
// hotkey_manager_linux 0.2.0 hands Flutter's physical keyCode straight to
// gtk_accelerator_name() as though it were a GDK keyval, so Relic's summon
// chord (Ctrl+Shift+Space) came out as "<Primary><Shift>KP_Space" — the
// KEYPAD space — and never fired. It also ignores keybinder_bind()'s return
// value and answers success unconditionally, so a refused grab looked like a
// working hotkey and Relic's "these hotkeys failed" surface stayed empty.
// Both verified on Ubuntu 24.04/Xorg (2026-08-18).
//
// Here Dart builds the accelerator (platform/global_hotkeys.dart) and this
// side reports what actually happened. Same shape as clipboard_watch.cc and
// the macOS Swift bridges: change the Dart and the C++ together.

static FlMethodChannel* g_channel = nullptr;
// accelerator -> id, so the keybinder callback (which only gets the
// accelerator) can name the binding for Dart. Also what unregisterAll walks.
static std::map<std::string, std::string>* g_bindings = nullptr;

static void handle_key_down(const char* keystring, void* user_data) {
  if (g_channel == nullptr || g_bindings == nullptr) {
    return;
  }
  auto it = g_bindings->find(std::string(keystring));
  if (it == g_bindings->end()) {
    return;
  }
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "id",
                           fl_value_new_string(it->second.c_str()));
  fl_method_channel_invoke_method(g_channel, "onKeyDown", args, nullptr,
                                  nullptr, nullptr);
}

// "ok" | "unmappable" | "taken". Anything thrown or missing on the Dart side
// becomes HotkeyFailure.unavailable there, so this only names real outcomes.
static const char* bind_one(const char* id, const char* accelerator) {
  guint keyval = 0;
  GdkModifierType mods = (GdkModifierType)0;
  gtk_accelerator_parse(accelerator, &keyval, &mods);
  if (keyval == 0) {
    return "unmappable";
  }
  // Rebinding the same accelerator would leak the old grab.
  auto existing = g_bindings->find(std::string(accelerator));
  if (existing != g_bindings->end()) {
    keybinder_unbind(accelerator, handle_key_down);
    g_bindings->erase(existing);
  }
  if (!keybinder_bind(accelerator, handle_key_down, nullptr)) {
    return "taken";  // another client already holds this grab
  }
  (*g_bindings)[std::string(accelerator)] = std::string(id);
  return "ok";
}

static void unbind_all() {
  if (g_bindings == nullptr) {
    return;
  }
  for (const auto& entry : *g_bindings) {
    keybinder_unbind(entry.first.c_str(), handle_key_down);
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
  g_bindings = new std::map<std::string, std::string>();
  // keybinder needs the X11 display; on Wayland it cannot grab at all and
  // Dart short-circuits before calling us.
  keybinder_init();

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(messenger, "relic/hotkeys",
                                    FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, method_call_cb, nullptr,
                                            nullptr);
}
