import Foundation

/// The Voice key gesture as a pure state machine, a line-for-line port of
/// windows/runner/voice_gesture.h. VoiceBridge owns the event tap, the timer,
/// the microphone worker and the overlay; this type only decides what a key
/// transition means. Keep the two in step: the Windows fixture
/// (voice_gesture_test.cpp) is the behaviour contract for both.
///
/// "alt" here is the Voice key: Right Alt on Windows, Right Option on a Mac.
enum VoiceAction { case candidate, held, latched, cancel, stop, stopNoInsert, altTap, altDown }
enum VoiceState { case idle, candidate, waiting, held, latched, processing }

struct VoiceDecision {
  var swallow = false
  var actions: [VoiceAction] = []
}

struct VoiceGesture {
  var state = VoiceState.idle
  var note = false
  var altDown = false
  var forwarding = false
  var latchRelease = false
  var ownedAlt = false
  var at: UInt64 = 0

  mutating func tick(_ now: UInt64) -> VoiceDecision {
    if state == .candidate && now &- at >= 200 {
      state = .held
      return VoiceDecision(swallow: false, actions: [.held])
    }
    if state == .waiting && now &- at > 350 {
      state = .idle
      return VoiceDecision(swallow: false, actions: [.altTap])
    }
    return VoiceDecision()
  }

  mutating func alt(down: Bool, ctrl: Bool, eligible: Bool, now: UInt64) -> VoiceDecision {
    if down == altDown { return VoiceDecision(swallow: ownedAlt && !forwarding, actions: []) }
    altDown = down
    if forwarding {
      if !down { forwarding = false; ownedAlt = false }
      return VoiceDecision()
    }
    if !down && (state == .idle || state == .processing) && ownedAlt {
      ownedAlt = false
      return VoiceDecision(swallow: true, actions: [])
    }
    if state == .processing { return VoiceDecision() }
    if state == .latched {
      if down { ownedAlt = true; latchRelease = false; return VoiceDecision(swallow: true, actions: []) }
      ownedAlt = false
      if latchRelease { latchRelease = false; return VoiceDecision(swallow: true, actions: []) }
      state = .processing
      return VoiceDecision(swallow: true, actions: [.stop])
    }
    if !down && (state == .held || (state == .candidate && now &- at >= 200)) {
      ownedAlt = false
      state = .processing
      return VoiceDecision(swallow: true, actions: [.stop])
    }
    if !down && state == .candidate {
      ownedAlt = false
      state = .waiting; at = now
      return VoiceDecision(swallow: true, actions: [.cancel])
    }
    if down && state == .waiting && now &- at <= 350 && ctrl == note && eligible {
      ownedAlt = true
      state = .latched; latchRelease = true
      return VoiceDecision(swallow: true, actions: [.candidate, .latched])
    }
    if down && eligible {
      ownedAlt = true
      let replay = state == .waiting
      state = .candidate; note = ctrl; at = now
      return VoiceDecision(swallow: true, actions: replay ? [.altTap, .candidate] : [.candidate])
    }
    return VoiceDecision()
  }

  mutating func other(down: Bool, escape: Bool) -> VoiceDecision {
    if escape && down && (state == .held || state == .latched || state == .candidate || state == .processing) {
      state = .idle
      return VoiceDecision(swallow: true, actions: [.cancel])
    }
    if !down { return VoiceDecision() }
    if state == .waiting {
      state = .idle
      return VoiceDecision(swallow: false, actions: [.altTap])
    }
    if !altDown { return VoiceDecision() }
    if state == .candidate {
      state = .idle; forwarding = true
      return VoiceDecision(swallow: false, actions: [.cancel, .altDown])
    }
    if state == .held {
      state = .processing; forwarding = true
      return VoiceDecision(swallow: false, actions: [.stopNoInsert, .altDown])
    }
    if state == .latched {
      forwarding = true
      return VoiceDecision(swallow: false, actions: [.altDown])
    }
    return VoiceDecision()
  }

  mutating func complete() {
    state = .idle
    latchRelease = false
  }
}
