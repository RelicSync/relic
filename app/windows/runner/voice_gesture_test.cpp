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

  // A hidden press may always stay hidden. A release may only be hidden when
  // the system never saw the press, or Right Alt stays down everywhere.
  assert(SafeSwallow(true, true, false));
  assert(SafeSwallow(true, true, true));
  assert(SafeSwallow(true, false, false));
  assert(!SafeSwallow(true, false, true));
  assert(!SafeSwallow(false, false, false));
  // The full stall: the press leaked through while the hook was late, and the
  // gesture (which thinks it hid the press) wants to hide the release.
  Gesture stall;
  assert(stall.Alt(true, false, true, 10000).swallow);  // system saw it anyway
  const auto late = stall.Alt(false, false, true, 10080);
  assert(late.swallow && !SafeSwallow(late.swallow, false, true));

  // Gesture timing uses when the key moved, not when the hook got to it.
  assert(EventTime(5000, 5000, 4700) == 4700);
  assert(EventTime(5000, 3u, 0xFFFFFFFFu) == 4996);  // 32-bit tick wrapped
  assert(EventTime(5000, 5000, 5000) == 5000);
  assert(EventTime(100, 5000, 4000) == 100);   // never before the clock began
  assert(EventTime(200000, 200000, 100) == 200000);  // implausibly old: use now
  // A late double tap is still a double tap when measured by key time.
  Gesture tap;
  tap.Alt(true, false, true, EventTime(9000, 9000, 8500));
  tap.Alt(false, false, true, EventTime(9000, 9000, 8580));
  assert(tap.Alt(true, false, true, EventTime(9000, 9000, 8700)).actions[1] == Action::latched);

  // Typed text goes out in batches that never split a surrogate pair.
  const std::wstring text = L"ab\U0001F600cd";  // a b hi lo c d
  assert(NextBatch(text, 0, 2) == 2);
  assert(NextBatch(text, 0, 3) == 4);  // the pair stays together
  assert(NextBatch(text, 4, 32) == 2);
  assert(NextBatch(text, 6, 32) == 0);
  assert(NextBatch(L"x\xD800", 0, 2) == 2);  // a lone high surrogate at the end
  std::cout << "Voice gesture timing, repeat, mode and chord checks passed\n";
}
