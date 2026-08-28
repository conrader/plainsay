//! Push-to-talk on Right Ctrl.
//!
//! Windows' `RegisterHotKey` API cannot register a modifier-only shortcut,
//! and the `global-hotkey` crate consequently does not map `ControlRight` on
//! Windows. A low-level keyboard hook is therefore the primary path here.
//! The hook callback does no work: it only posts a small event to a bounded
//! channel and returns, keeping comfortably inside Windows' hook watchdog.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyEvent {
    Pressed,
    Released,
}

pub type EventReceiver = std::sync::mpsc::Receiver<Result<HotkeyEvent, String>>;

#[cfg(target_os = "windows")]
mod platform {
    use super::HotkeyEvent;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc::{sync_channel, SyncSender};
    use std::sync::OnceLock;
    use windows::Win32::Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_RCONTROL};
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW, TranslateMessage,
        UnhookWindowsHookEx, HC_ACTION, KBDLLHOOKSTRUCT, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP,
        WM_SYSKEYDOWN, WM_SYSKEYUP,
    };

    type HookMessage = Result<HotkeyEvent, String>;

    static EVENT_SENDER: OnceLock<SyncSender<HookMessage>> = OnceLock::new();
    static RIGHT_CTRL_DOWN: AtomicBool = AtomicBool::new(false);

    /// Installs the hook on a dedicated Win32 message-pump thread. The caller
    /// receives events and may keep the WASAPI stream on its own dispatch
    /// thread while also polling capture health and the recording limit.
    pub fn start() -> Result<super::EventReceiver, String> {
        let (event_tx, event_rx) = sync_channel::<HookMessage>(64);
        EVENT_SENDER
            .set(event_tx)
            .map_err(|_| "Right Ctrl listener is already running".to_string())?;

        let (ready_tx, ready_rx) = sync_channel::<Result<(), String>>(1);
        std::thread::Builder::new()
            .name("plainsay-hotkey-hook".to_string())
            .spawn(move || run_message_loop(ready_tx))
            .map_err(|e| format!("Could not start the hotkey hook: {e}"))?;

        ready_rx
            .recv()
            .map_err(|_| "The hotkey hook stopped during startup".to_string())??;
        Ok(event_rx)
    }

    pub fn is_pressed() -> bool {
        (unsafe { GetAsyncKeyState(VK_RCONTROL.0 as i32) }) < 0
    }

    fn run_message_loop(ready: SyncSender<Result<(), String>>) {
        let module = match unsafe { GetModuleHandleW(None) } {
            Ok(module) => HINSTANCE(module.0),
            Err(error) => {
                let _ = ready.send(Err(format!(
                    "Could not find the Plainsay module for the Right Ctrl hook: {error}"
                )));
                return;
            }
        };
        let hook = match unsafe {
            SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), Some(module), 0)
        } {
            Ok(hook) => hook,
            Err(error) => {
                let _ = ready.send(Err(format!(
                    "Could not install the Right Ctrl hook: {error}"
                )));
                return;
            }
        };

        if ready.send(Ok(())).is_err() {
            let _ = unsafe { UnhookWindowsHookEx(hook) };
            return;
        }

        let mut message = MSG::default();
        loop {
            let status = unsafe { GetMessageW(&mut message, None, 0, 0) }.0;
            if status == -1 {
                send_message(Err("The Right Ctrl message loop failed".to_string()));
                break;
            }
            if status == 0 {
                send_message(Err("The Right Ctrl message loop stopped".to_string()));
                break;
            }
            unsafe {
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }

        let _ = unsafe { UnhookWindowsHookEx(hook) };
    }

    unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code == HC_ACTION as i32 {
            let key = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
            if key.vkCode == VK_RCONTROL.0 as u32 {
                let message = wparam.0 as u32;
                if message == WM_KEYDOWN || message == WM_SYSKEYDOWN {
                    if !RIGHT_CTRL_DOWN.swap(true, Ordering::AcqRel) {
                        send_message(Ok(HotkeyEvent::Pressed));
                    }
                } else if (message == WM_KEYUP || message == WM_SYSKEYUP)
                    && RIGHT_CTRL_DOWN.swap(false, Ordering::AcqRel)
                {
                    send_message(Ok(HotkeyEvent::Released));
                }

                // Right Ctrl is Plainsay's dedicated push-to-talk key while
                // the app is running; do not leak it into the focused app.
                return LRESULT(1);
            }
        }

        unsafe { CallNextHookEx(None, code, wparam, lparam) }
    }

    fn send_message(message: HookMessage) {
        if let Some(sender) = EVENT_SENDER.get() {
            // Never block inside the low-level hook callback. There can only
            // be one meaningful press and release at a time; repeats are
            // deduplicated above, and a bounded queue protects the process.
            let _ = sender.try_send(message);
        }
    }
}

#[cfg(not(target_os = "windows"))]
mod platform {
    pub fn start() -> Result<super::EventReceiver, String> {
        Err("The Right Ctrl listener is only available on Windows".to_string())
    }

    pub fn is_pressed() -> bool {
        false
    }
}

pub use platform::{is_pressed, start};
