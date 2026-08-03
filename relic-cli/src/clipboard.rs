//! System clipboard write (the agent->human handoff primitive). Windows only;
//! other platforms return a clear error.

use anyhow::Result;

#[cfg(windows)]
pub fn set_text(text: &str) -> Result<()> {
    win::set_text(text)
}

#[cfg(not(windows))]
pub fn set_text(_text: &str) -> Result<()> {
    Err(crate::error::ExitError::new(1, "`relic copy` is only supported on Windows").into())
}

#[cfg(windows)]
mod win {
    use anyhow::{bail, Result};
    use std::ffi::c_void;
    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
    };
    use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};

    const CF_UNICODETEXT: u32 = 13;

    pub fn set_text(text: &str) -> Result<()> {
        // UTF-16LE, null-terminated.
        let mut units: Vec<u16> = text.encode_utf16().collect();
        units.push(0);
        let byte_len = units.len() * 2;

        unsafe {
            if OpenClipboard(std::ptr::null_mut()) == 0 {
                bail!("OpenClipboard failed");
            }
            // Ensure the clipboard is closed on every path.
            let result = (|| {
                if EmptyClipboard() == 0 {
                    bail!("EmptyClipboard failed");
                }
                let hmem = GlobalAlloc(GMEM_MOVEABLE, byte_len);
                if hmem.is_null() {
                    bail!("GlobalAlloc failed");
                }
                let ptr = GlobalLock(hmem) as *mut u16;
                if ptr.is_null() {
                    bail!("GlobalLock failed");
                }
                std::ptr::copy_nonoverlapping(units.as_ptr(), ptr, units.len());
                GlobalUnlock(hmem);
                if SetClipboardData(CF_UNICODETEXT, hmem as HANDLE).is_null() {
                    // System did not take ownership; we'd leak hmem, but a failed
                    // SetClipboardData is rare and the process is short-lived.
                    bail!("SetClipboardData failed");
                }
                Ok(())
            })();
            let _ = CloseClipboard();
            result
        }
    }

    // keep the import used even if c_void isn't referenced directly
    #[allow(dead_code)]
    fn _assert(_: *mut c_void) {}
}
