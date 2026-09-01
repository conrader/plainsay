//! Safe-ish Windows text insertion: copy, verify the original target still
//! owns focus, then synthesize Ctrl+V. The transcript remains on the clipboard
//! whenever paste cannot be guaranteed, so a failed insertion never loses it.

use arboard::Clipboard;

#[derive(Debug, Clone, Copy)]
pub struct InsertionTarget {
    window: usize,
    focused_control: Option<usize>,
    terminal: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum InsertionError {
    #[error("could not access the clipboard: {0}")]
    Clipboard(String),
    #[error("keyboard focus changed while the dictation was processing")]
    FocusChanged,
    #[error("a modifier key is still held; release it and paste the transcript manually")]
    ModifierPressed,
    #[error("Windows accepted only {accepted} of {expected} paste key events")]
    PasteRejected { accepted: u32, expected: u32 },
}

impl InsertionError {
    pub fn transcript_is_on_clipboard(&self) -> bool {
        !matches!(self, Self::Clipboard(_))
    }
}

/// Captures the focused window at key-down. A network round trip can take a
/// few seconds; pasting into whichever app happens to be focused afterward is
/// surprising and can be dangerous, especially in terminals.
#[cfg(target_os = "windows")]
pub fn capture_target() -> Option<InsertionTarget> {
    use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;

    let window = unsafe { GetForegroundWindow() };
    if window.is_invalid() {
        return None;
    }
    Some(InsertionTarget {
        window: window.0 as usize,
        focused_control: focused_control(window).map(|focused| focused.0 as usize),
        terminal: is_terminal(window),
    })
}

#[cfg(not(target_os = "windows"))]
pub fn capture_target() -> Option<InsertionTarget> {
    None
}

/// Places the sanitized transcript on the clipboard and pastes only if the
/// window captured at key-down still owns focus. In console/terminal targets,
/// line breaks are flattened so dictation cannot accidentally execute a
/// command merely by being pasted.
pub fn insert(text: &str, target: Option<InsertionTarget>) -> Result<(), InsertionError> {
    let text = sanitize_for_insertion(text, target.is_some_and(|target| target.terminal));
    let mut clipboard = Clipboard::new().map_err(|e| InsertionError::Clipboard(e.to_string()))?;

    clipboard
        .set_text(text)
        .map_err(|e| InsertionError::Clipboard(e.to_string()))?;

    // Let clipboard ownership settle before the synthetic shortcut. Some
    // Office/Electron targets otherwise observe the prior clipboard value.
    std::thread::sleep(std::time::Duration::from_millis(20));

    if !target_is_still_focused(target) {
        return Err(InsertionError::FocusChanged);
    }
    send_paste()?;

    Ok(())
}

fn sanitize_for_insertion(text: &str, terminal: bool) -> String {
    let normalized = text.replace("\r\n", "\n");
    normalized
        .chars()
        .filter_map(|character| {
            if terminal && matches!(character, '\n' | '\r') {
                return Some(' ');
            }
            if character == '\r' {
                return None;
            }
            if character == '\n' || character == '\t' {
                return Some(character);
            }
            if character.is_control() {
                return None;
            }
            Some(character)
        })
        .collect()
}

#[cfg(target_os = "windows")]
fn target_is_still_focused(target: Option<InsertionTarget>) -> bool {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;

    let Some(target) = target else { return false };
    let expected = HWND(target.window as *mut std::ffi::c_void);
    if unsafe { GetForegroundWindow() } != expected {
        return false;
    }
    match target.focused_control {
        Some(focused) => {
            let expected_focus = HWND(focused as *mut std::ffi::c_void);
            focused_control(expected) == Some(expected_focus)
        }
        None => true,
    }
}

#[cfg(not(target_os = "windows"))]
fn target_is_still_focused(_target: Option<InsertionTarget>) -> bool {
    true
}

#[cfg(target_os = "windows")]
fn send_paste() -> Result<(), InsertionError> {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS,
        KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT, VK_V,
    };

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

    let modifiers = [VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN];
    if modifiers
        .iter()
        .any(|key| unsafe { GetAsyncKeyState(key.0 as i32) } < 0)
    {
        return Err(InsertionError::ModifierPressed);
    }

    let inputs = [
        key_input(VK_CONTROL, false),
        key_input(VK_V, false),
        key_input(VK_V, true),
        key_input(VK_CONTROL, true),
    ];
    let accepted = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if accepted != inputs.len() as u32 {
        // A partial SendInput can leave our synthetic Ctrl or V down. These
        // best-effort key-up events repair that state without touching any
        // physically held modifier (those were rejected above).
        let releases = [key_input(VK_V, true), key_input(VK_CONTROL, true)];
        let _ = unsafe { SendInput(&releases, std::mem::size_of::<INPUT>() as i32) };
        return Err(InsertionError::PasteRejected {
            accepted,
            expected: inputs.len() as u32,
        });
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn focused_control(
    window: windows::Win32::Foundation::HWND,
) -> Option<windows::Win32::Foundation::HWND> {
    use windows::Win32::UI::WindowsAndMessaging::{
        GetGUIThreadInfo, GetWindowThreadProcessId, GUITHREADINFO,
    };

    let thread_id = unsafe { GetWindowThreadProcessId(window, None) };
    if thread_id == 0 {
        return None;
    }
    let mut info = GUITHREADINFO {
        cbSize: std::mem::size_of::<GUITHREADINFO>() as u32,
        ..Default::default()
    };
    unsafe { GetGUIThreadInfo(thread_id, &mut info) }.ok()?;
    (!info.hwndFocus.is_invalid()).then_some(info.hwndFocus)
}

#[cfg(not(target_os = "windows"))]
fn send_paste() -> Result<(), InsertionError> {
    Ok(())
}

#[cfg(target_os = "windows")]
fn is_terminal(window: windows::Win32::Foundation::HWND) -> bool {
    use std::path::Path;
    use windows::core::PWSTR;
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::WindowsAndMessaging::{GetClassNameW, GetWindowThreadProcessId};

    let mut class_name = [0u16; 256];
    let class_length = unsafe { GetClassNameW(window, &mut class_name) }.max(0) as usize;
    let class_name = String::from_utf16_lossy(&class_name[..class_length]).to_ascii_lowercase();
    if class_name.contains("consolewindowclass") || class_name.contains("cascadia") {
        return true;
    }

    let mut process_id = 0;
    unsafe { GetWindowThreadProcessId(window, Some(&mut process_id)) };
    if process_id == 0 {
        return false;
    }
    let Ok(process) =
        (unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, process_id) })
    else {
        return false;
    };

    let mut path = [0u16; 32_768];
    let mut path_length = path.len() as u32;
    let query = unsafe {
        QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(path.as_mut_ptr()),
            &mut path_length,
        )
    };
    let _ = unsafe { CloseHandle(process) };
    if query.is_err() {
        return false;
    }

    let executable = String::from_utf16_lossy(&path[..path_length as usize]);
    let name = Path::new(&executable)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        name.as_str(),
        "windowsterminal.exe"
            | "openconsole.exe"
            | "cmd.exe"
            | "powershell.exe"
            | "pwsh.exe"
            | "conhost.exe"
            | "mintty.exe"
            | "wezterm-gui.exe"
            | "alacritty.exe"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_control_characters_but_keeps_paragraphs() {
        assert_eq!(
            sanitize_for_insertion("hello\0\u{001b}\tworld\r\nnext", false),
            "hello\tworld\nnext"
        );
    }

    #[test]
    fn flattens_terminal_newlines() {
        assert_eq!(
            sanitize_for_insertion("echo one\r\necho two", true),
            "echo one echo two"
        );
    }
}
