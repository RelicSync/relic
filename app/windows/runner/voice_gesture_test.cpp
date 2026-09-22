#include "voice_gesture.h"
#include <cassert>
#include <iostream>
using namespace relic_voice;
int main() {
  Gesture g;
  assert(g.Alt(true, false, true, 0).swallow);
  assert(g.Tick(199).actions.empty());
  assert(g.Tick(200).actions[0] == Action::held);
  assert(g.Alt(true, false, true, 205).actions.empty());
  assert(g.Alt(false, false, true, 400).actions[0] == Action::stop);
  assert(g.state == State::processing);
  g.Complete();
  g.Alt(true, true, true, 1000);
  assert(g.Alt(false, true, true, 1050).actions[0] == Action::cancel);
  assert(g.Alt(true, true, true, 1250).actions[1] == Action::latched);
  assert(g.note);
  assert(g.Alt(false, false, true, 1300).actions.empty());
  assert(g.Other(true, false).actions.empty());
  g.Alt(true, false, true, 1500);
  assert(g.Alt(false, false, true, 1550).actions[0] == Action::stop);
  g.Complete();
  g.Alt(true, false, true, 2000);
  assert(g.Other(true, false).actions[1] == Action::alt_down);
  assert(!g.Alt(false, false, true, 2200).swallow);
  g.Alt(true, false, true, 2300); g.Alt(false, false, true, 2350);
  assert(g.Tick(2701).actions[0] == Action::alt_tap);
  assert(!g.Alt(true, false, false, 3000).swallow);
  g.Alt(false, false, false, 3050);
  g.Alt(true, false, true, 4000); g.Tick(4200);
  assert(g.Other(true, false).actions[0] == Action::stop_no_insert);
  std::cout << "Voice gesture timing, repeat, mode and chord checks passed\n";
}
