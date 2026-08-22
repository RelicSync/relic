#include "my_application.h"
#include "single_instance.h"

int main(int argc, char** argv) {
  // One Relic per vault. Losing this race is the normal way a second launch
  // ends: the running copy has already been asked to surface its window, so
  // this process has nothing left to do and exits successfully.
  if (!relic_single_instance_acquire()) {
    return 0;
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
