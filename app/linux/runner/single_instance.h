#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <gtk/gtk.h>

// Take the single-instance lock for this vault. True: we are the only copy and
// should start. False: another copy already owns this vault, it has been asked
// to surface its window, and this process should exit quietly with success.
//
// Call before creating the GtkApplication. The lock is held for the lifetime of
// the process; the kernel releases it on exit or crash.
bool relic_single_instance_acquire();

// Publish this process's toplevel so the NEXT launch can find it, and start
// listening for that launch's request. Call once the window exists.
void relic_single_instance_publish(GtkWindow* window);

#endif  // RUNNER_SINGLE_INSTANCE_H_
