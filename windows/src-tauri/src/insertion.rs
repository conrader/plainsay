//! Paste-based text insertion: clipboard write + simulated Ctrl+V via
//! `SendInput`. Windows has no clean "insert text at cursor" API — UI
//! Automation's `TextPattern` can't insert — so this is the same tradeoff the
//! Mac client already made, with Windows' own edge cases (see
//! `windows/PLAN.md`):
//!
//! - A UAC-elevated target window blocks synthetic input from a
//!   non-elevated process by design (UIPI). There's no clean workaround,
//!   only detection: `SendInput` succeeds even when the keystrokes are
//!   silently dropped by the elevated target, so this can't be reported as a
//!   normal error — it just won't paste.
//! - A raw inserted newline can trigger command execution in a shell. Only
//!   CRLF is normalized to LF here (see `insert` below) — newlines are NOT
//!   flattened or stripped, and the Mac client has no terminal-aware
//!   handling to mirror either (it strips genuine control bytes but
//!   deliberately keeps `\n`/`\t`, matching Polishing's own paragraph
//!   breaks). Real terminal-injection hardening is still a TODO on both
//!   clients, not implemented on either.

use arboard::Clipboard;

#[cfg(target_os = "windows")]
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY, VK_CONTROL, VK_V,
};

#[derive(Debug, thiserror::Error)]
pub enum InsertionError {
    #[error("could not access the clipboard: {0}")]
    Clipboard(String),
}

/// Writes `text` to the clipboard and simulates Ctrl+V at the current
/// keyboard focus. Restores whatever was previously on the clipboard
/// afterward, matching the Mac client's "leave no trace" behavior — dictation
/// shouldn't quietly become the user's next Ctrl+V outside the app.
pub fn insert(text: &str) -> Result<(), InsertionError> {
    // CRLF -> LF only. This does not address the shell-injection hazard
    // described above — see the module doc comment.
    let text = text.replace("\r\n", "\n");

    let mut clipboard = Clipboard::new().map_err(|e| InsertionError::Clipboard(e.to_string()))?;
    let previous = clipboard.get_text().ok();

    clipboard
        .set_text(text)
        .map_err(|e| InsertionError::Clipboard(e.to_string()))?;

    send_paste();

    if let Some(previous) = previous {
        // Best-effort: the paste above needs a moment to actually be read by
        // the target application before the clipboard changes under it.
        std::thread::sleep(std::time::Duration::from_millis(200));
        let _ = clipboard.set_text(previous);
    }

    Ok(())
}

#[cfg(target_os = "windows")]
fn send_paste() {
    let inputs = [
        key_input(VK_CONTROL, false),
        key_input(VK_V, false),
        key_input(VK_V, true),
        key_input(VK_CONTROL, true),
    ];
    unsafe {
        SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

#[cfg(target_os = "windows")]
fn key_input(key: VIRTUAL_KEY, key_up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: key,
                wScan: 0,
                dwFlags: if key_up {
                    KEYEVENTF_KEYUP
                } else {
                    KEYBD_EVENT_FLAGS(0)
                },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

#[cfg(not(target_os = "windows"))]
fn send_paste() {
    // Non-Windows builds only exist for local `cargo check` while developing
    // from a Mac — there is no real target to paste into.
}
