#include "single_instance.h"

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <errno.h>
#include <fcntl.h>
#include <gdk/gdkx.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

// One Relic per vault.
//
// A second copy must not start: two processes writing the same SQLite WAL is a
// corruption risk, and the user would get a duplicate tray icon and two
// clipboard watchers racing to capture every copy. Windows guards this with a
// named mutex (windows/runner/main.cpp) and macOS gets it from Launch Services;
// Linux has neither, and the scaffold deliberately registers GApplication as
// NON_UNIQUE so the guard is ours to write — GApplication's own uniqueness keys
// off the application id, which cannot tell two vaults apart.
//
// The lock is an flock() on a file in the DATA DIR, so it is scoped to the
// vault rather than to the user: a RELIC_DATA_DIR instance (portable mode, a
// sandboxed test copy) has its own database and so is safe to run alongside the
// normal one, exactly like the Windows mutex name carrying the data dir. The
// kernel drops an flock when the fd closes, including on a crash or a SIGKILL,
// so a dead instance never locks the user out — which is the failure mode of
// every pidfile scheme that tries to do this by hand.
//
// Losing the race is not an error. The user asked for Relic, so the copy that
// is already running surfaces its window and the new process exits 0. The
// handoff is an X ClientMessage to the running window (its id is published in
// the lock file), caught by a GDK filter. Dart is not told: desktop.dart's
// onWindowFocus already adopts a window that appeared without it, which is the
// same path the Windows RelicShowExisting broadcast takes.

static const char* kShowMessage = "_RELIC_SHOW_EXISTING";

static int g_lock_fd = -1;
static GtkWindow* g_window = nullptr;

// Relic's data dir, resolved exactly as platform/paths.dart does it on Linux:
// RELIC_DATA_DIR wins, then $XDG_DATA_HOME/relic, then ~/.local/share/relic.
// Empty when there is no home to fall back on.
static std::string data_dir() {
  const char* override_dir = g_getenv("RELIC_DATA_DIR");
  if (override_dir != nullptr && override_dir[0] != '\0') {
    return override_dir;
  }
  const char* xdg = g_getenv("XDG_DATA_HOME");
  if (xdg != nullptr && xdg[0] != '\0') {
    return std::string(xdg) + "/relic";
  }
  const char* home = g_getenv("HOME");
  if (home == nullptr || home[0] == '\0') {
    return std::string();
  }
  return std::string(home) + "/.local/share/relic";
}

// The window id the running instance published, or 0 when there is none yet
// (it is still starting up, or it is a Wayland session with no X window).
static Window read_published_window(int fd) {
  char buf[32] = {0};
  ssize_t n = pread(fd, buf, sizeof(buf) - 1, 0);
  if (n <= 0) {
    return 0;
  }
  return static_cast<Window>(strtoul(buf, nullptr, 10));
}

// Ask the copy that owns the lock to show itself. Best-effort by nature: this
// process is about to exit either way, and a failure here costs the user a
// click on the tray, not their data.
static void ask_running_instance_to_show(Window target) {
  if (target == 0) {
    return;
  }
  // gtk_init has not run yet at this point (we are called before the
  // GtkApplication exists), so talk to X directly.
  Display* dpy = XOpenDisplay(nullptr);
  if (dpy == nullptr) {
    return;
  }
  XEvent event;
  memset(&event, 0, sizeof(event));
  event.xclient.type = ClientMessage;
  event.xclient.window = target;
  event.xclient.message_type = XInternAtom(dpy, kShowMessage, False);
  event.xclient.format = 32;
  // An empty event mask delivers the message to the client that created the
  // window, which is the running instance — no event selection needed there.
  XSendEvent(dpy, target, False, NoEventMask, &event);
  XFlush(dpy);
  XCloseDisplay(dpy);
}

bool relic_single_instance_acquire() {
  const std::string dir = data_dir();
  if (dir.empty()) {
    return true;  // nowhere to put a lock: never block the app over it
  }
  if (g_mkdir_with_parents(dir.c_str(), 0700) != 0) {
    return true;
  }
  const std::string path = dir + "/instance.lock";
  int fd = open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) {
    return true;
  }
  if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
    g_lock_fd = fd;  // held until this process dies; never closed on purpose
    return true;
  }
  if (errno != EWOULDBLOCK) {
    close(fd);
    return true;  // an unexpected lock failure must not be a startup failure
  }
  ask_running_instance_to_show(read_published_window(fd));
  close(fd);
  return false;
}

static GdkFilterReturn show_request_filter(GdkXEvent* gdk_xevent,
                                           GdkEvent* /*event*/,
                                           gpointer /*data*/) {
  XEvent* xevent = reinterpret_cast<XEvent*>(gdk_xevent);
  if (xevent->type != ClientMessage || g_window == nullptr) {
    return GDK_FILTER_CONTINUE;
  }
  static Atom show_atom = None;
  if (show_atom == None) {
    show_atom = XInternAtom(xevent->xclient.display, kShowMessage, False);
  }
  if (xevent->xclient.message_type != show_atom) {
    return GDK_FILTER_CONTINUE;
  }
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(g_window));
  if (gdk_window != nullptr) {
    // The user launching Relic IS the user event this focus request points at,
    // and there is no press to borrow a timestamp from, so ask the server for
    // now — the same honest fallback window_focus.cc uses for a tray summon.
    guint32 when = gdk_x11_get_server_time(gdk_window);
    gdk_x11_window_set_user_time(gdk_window, when);
    gtk_window_present_with_time(g_window, when);
  } else {
    gtk_window_present(g_window);
  }
  return GDK_FILTER_REMOVE;
}

static void publish_now() {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(g_window));
  if (gdk_window == nullptr || !GDK_IS_X11_WINDOW(gdk_window)) {
    // Wayland: the lock still keeps a second copy from starting, but there is
    // no X window to hand off to, so that copy exits without surfacing this
    // one. Honest degradation, same stance as the rest of the Linux port.
    return;
  }
  gdk_window_add_filter(gdk_window, show_request_filter, nullptr);
  if (g_lock_fd < 0) {
    return;
  }
  char buf[32];
  int n = snprintf(buf, sizeof(buf), "%lu\n",
                   static_cast<unsigned long>(gdk_x11_window_get_xid(gdk_window)));
  if (n > 0 && ftruncate(g_lock_fd, 0) == 0) {
    ssize_t written = pwrite(g_lock_fd, buf, n, 0);
    (void)written;  // a failed publish costs the handoff, not the lock
  }
}

static void on_window_realized(GtkWidget* /*widget*/, gpointer /*data*/) {
  publish_now();
}

void relic_single_instance_publish(GtkWindow* window) {
  g_window = window;
  if (gtk_widget_get_window(GTK_WIDGET(window)) != nullptr) {
    publish_now();
  } else {
    g_signal_connect(window, "realize", G_CALLBACK(on_window_realized),
                     nullptr);
  }
}
