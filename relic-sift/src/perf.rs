//! CPU budget for the on-device passes.
//!
//! Labeling costs roughly 7.5 core-seconds per item. On a 16-thread desktop
//! that is background noise; on a 4-thread laptop it is most of the machine,
//! and the old fixed 6 intra-op threads *oversubscribed* such a machine —
//! six threads contending for four cores is slower than asking for two, not
//! faster. So the thread count scales with the host, and the process drops
//! below foreground priority so the OS preempts it for whatever the user is
//! actually doing.

use std::str::FromStr;

/// How much of the machine the on-device passes may take.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Speed {
    /// Stay out of the way on modest hardware.
    Gentle,
    /// Below-foreground priority, most of the spare cores. The default: on a
    /// large machine it is identical to the old fixed 6, so nothing regresses.
    #[default]
    Balanced,
    /// Finish as fast as possible, at normal priority. The user's call to make.
    Fast,
}

impl FromStr for Speed {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, String> {
        match s.trim().to_ascii_lowercase().as_str() {
            "gentle" | "low" => Ok(Speed::Gentle),
            "balanced" | "normal" => Ok(Speed::Balanced),
            "fast" | "full" => Ok(Speed::Fast),
            other => Err(format!("unknown speed '{other}' (gentle|balanced|fast)")),
        }
    }
}

impl Speed {
    /// Whether this profile yields to foreground work.
    pub fn below_normal(self) -> bool {
        self != Speed::Fast
    }
}

/// The profile for this process. Process-global on purpose: priority already
/// is, and it spares threading a parameter through every session constructor.
/// Set once at startup, before any model loads.
static SPEED: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(1);

pub fn set_speed(speed: Speed) {
    let v = match speed {
        Speed::Gentle => 0,
        Speed::Balanced => 1,
        Speed::Fast => 2,
    };
    SPEED.store(v, std::sync::atomic::Ordering::Relaxed);
}

pub fn speed() -> Speed {
    match SPEED.load(std::sync::atomic::Ordering::Relaxed) {
        0 => Speed::Gentle,
        2 => Speed::Fast,
        _ => Speed::Balanced,
    }
}

/// Intra-op threads for the profile this process is running under.
pub fn current_threads() -> usize {
    threads(speed())
}

fn cores() -> usize {
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4)
}

/// Intra-op threads for the labeler's ONNX sessions.
///
/// `SIFT_THREADS` overrides everything — the Python parity harness pins it, and
/// a changed reduction order could in principle move a near-tie argmax and
/// break token-for-token comparison.
pub fn threads(speed: Speed) -> usize {
    if let Ok(n) = std::env::var("SIFT_THREADS") {
        if let Ok(n) = n.trim().parse::<usize>() {
            if n >= 1 {
                return n;
            }
        }
    }
    threads_for(speed, cores())
}

/// Pure half of [`threads`], so the sizing is testable without a machine of
/// each shape. Never returns 0, and never exceeds what the host actually has.
pub fn threads_for(speed: Speed, cores: usize) -> usize {
    let cores = cores.max(1);
    let n = match speed {
        // A quarter of the box, so even a 2-core machine keeps one core clear.
        Speed::Gentle => cores / 4,
        // Leave two for the foreground; the 6 cap is where these q4f16 graphs
        // stop scaling anyway (they are memory-bandwidth-bound, not compute).
        Speed::Balanced => cores.saturating_sub(2).min(6),
        Speed::Fast => cores.min(8),
    };
    n.max(1).min(cores)
}

/// Drop this process below foreground priority, so a long backlog can't make
/// the machine feel stalled. Best-effort: a failure here is never worth
/// failing a classification over.
pub fn lower_priority(speed: Speed) {
    if !speed.below_normal() {
        return;
    }
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::Threading::{
            GetCurrentProcess, SetPriorityClass, BELOW_NORMAL_PRIORITY_CLASS,
        };
        SetPriorityClass(GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
    }
    // Unix: nothing yet. setpriority(2) would need libc, and the desktop app
    // this serves is Windows-only today.
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn balanced_matches_the_old_fixed_count_on_a_big_machine() {
        // The pre-existing behaviour was a hardcoded 6. Anything with 8+ cores
        // must keep getting exactly that, so no desktop user regresses.
        for cores in [8, 12, 16, 32] {
            assert_eq!(threads_for(Speed::Balanced, cores), 6, "cores={cores}");
        }
    }

    /// The bug this exists to fix: 6 threads on a 4-thread laptop.
    #[test]
    fn balanced_never_oversubscribes_a_small_machine() {
        assert_eq!(threads_for(Speed::Balanced, 4), 2);
        assert_eq!(threads_for(Speed::Balanced, 2), 1);
        for cores in 1..=64 {
            assert!(
                threads_for(Speed::Balanced, cores) <= cores,
                "cores={cores} asked for more threads than exist"
            );
        }
    }

    #[test]
    fn every_profile_asks_for_at_least_one_thread() {
        for speed in [Speed::Gentle, Speed::Balanced, Speed::Fast] {
            for cores in 0..=64 {
                let n = threads_for(speed, cores);
                assert!(n >= 1, "{speed:?} cores={cores} -> {n}");
                assert!(n <= cores.max(1), "{speed:?} cores={cores} -> {n}");
            }
        }
    }

    #[test]
    fn gentle_leaves_headroom_and_fast_takes_more() {
        assert_eq!(threads_for(Speed::Gentle, 16), 4);
        assert_eq!(threads_for(Speed::Gentle, 4), 1);
        assert_eq!(threads_for(Speed::Fast, 16), 8);
        for cores in [4, 8, 16] {
            assert!(
                threads_for(Speed::Gentle, cores) <= threads_for(Speed::Balanced, cores),
                "gentle must never exceed balanced (cores={cores})"
            );
            assert!(
                threads_for(Speed::Balanced, cores) <= threads_for(Speed::Fast, cores),
                "balanced must never exceed fast (cores={cores})"
            );
        }
    }

    #[test]
    fn only_fast_keeps_foreground_priority() {
        assert!(Speed::Gentle.below_normal());
        assert!(Speed::Balanced.below_normal());
        assert!(!Speed::Fast.below_normal());
    }

    #[test]
    fn speed_parses_the_names_the_cli_and_app_use() {
        assert_eq!("gentle".parse(), Ok(Speed::Gentle));
        assert_eq!("balanced".parse(), Ok(Speed::Balanced));
        assert_eq!("FAST".parse(), Ok(Speed::Fast));
        assert_eq!(Speed::default(), Speed::Balanced);
        assert!("sideways".parse::<Speed>().is_err());
    }
}
