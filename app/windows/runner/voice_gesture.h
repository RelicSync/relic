#pragma once
#include <cstdint>
#include <vector>

// Pure physical-key state machine; Win32 adapters own timers, audio and UI.
namespace relic_voice {
enum class Action { candidate, held, latched, cancel, stop, stop_no_insert, alt_tap, alt_down };
enum class State { idle, candidate, waiting, held, latched, processing };
struct Decision { bool swallow = false; std::vector<Action> actions; };
class Gesture {
 public:
  State state = State::idle;
  bool note = false;
  bool alt_down = false;
  bool forwarding = false;
  bool latch_release = false;
  bool owned_alt = false;
  uint64_t at = 0;

  Decision Tick(uint64_t now) {
    if (state == State::candidate && now - at >= 200) {
      state = State::held;
      return {false, {Action::held}};
    }
    if (state == State::waiting && now - at > 350) {
      state = State::idle;
      return {false, {Action::alt_tap}};
    }
    return {};
  }
  Decision Alt(bool down, bool ctrl, bool eligible, uint64_t now) {
    if (down == alt_down) return {owned_alt && !forwarding, {}};
    alt_down = down;
    if (forwarding) {
      if (!down) { forwarding = false; owned_alt = false; }
      return {};
    }
    if (!down && (state == State::idle || state == State::processing) && owned_alt) {
      owned_alt = false;
      return {true, {}};
    }
    if (state == State::processing) return {};
    if (state == State::latched) {
      if (down) { owned_alt = true; latch_release = false; return {true, {}}; }
      owned_alt = false;
      if (latch_release) { latch_release = false; return {true, {}}; }
      owned_alt = false;
      state = State::processing;
      return {true, {Action::stop}};
    }
    if (!down && (state == State::held || (state == State::candidate && now - at >= 200))) {
      owned_alt = false;
      state = State::processing;
      return {true, {Action::stop}};
    }
    if (!down && state == State::candidate) {
      owned_alt = false;
      state = State::waiting; at = now;
      return {true, {Action::cancel}};
    }
    if (down && state == State::waiting && now - at <= 350 && ctrl == note && eligible) {
      owned_alt = true;
      state = State::latched; latch_release = true;
      return {true, {Action::candidate, Action::latched}};
    }
    if (down && eligible) {
      owned_alt = true;
      const bool replay = state == State::waiting;
      state = State::candidate; note = ctrl; at = now;
      return {true, replay ? std::vector<Action>{Action::alt_tap, Action::candidate} : std::vector<Action>{Action::candidate}};
    }
    return {};
  }
  Decision Other(bool down, bool escape) {
    if (escape && down && (state == State::held || state == State::latched || state == State::candidate || state == State::processing)) {
      state = State::idle;
      return {true, {Action::cancel}};
    }
    if (!down) return {};
    if (state == State::waiting) {
      state = State::idle;
      return {false, {Action::alt_tap}};
    }
    if (!alt_down) return {};
    if (state == State::candidate) {
      state = State::idle; forwarding = true;
      return {false, {Action::cancel, Action::alt_down}};
    }
    if (state == State::held) {
      state = State::processing; forwarding = true;
      return {false, {Action::stop_no_insert, Action::alt_down}};
    }
    if (state == State::latched) {
      forwarding = true;
      return {false, {Action::alt_down}};
    }
    return {};
  }
  void Complete() { state = State::idle; latch_release = false; }
};
}  // namespace relic_voice
