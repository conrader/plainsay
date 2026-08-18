//! Push-to-talk hotkey. `global-hotkey` is RegisterHotKey-based but does
//! expose press/release, not just a fired toggle — confirmed against its own
//! source (see `windows/PLAN.md`) — so hold-to-talk works without a raw
//! low-level keyboard hook. That hook stays a documented fallback for the one
//! case this can't handle: the chosen key already claimed system-wide by
//! another app, which makes `RegisterHotKey` fail outright.

use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};

/// Right Ctrl: unlikely to collide with another app's global hotkey, and
/// distinct from the left-hand modifiers used in normal typing shortcuts.
/// Should become user-configurable before this ships — tracked as a known
/// gap, not a final decision.
pub fn default_hotkey() -> HotKey {
    HotKey::new(Some(Modifiers::empty()), Code::ControlRight)
}

pub struct Hotkey {
    _manager: GlobalHotKeyManager,
    id: u32,
}

impl Hotkey {
    /// Registers the given hotkey. Kept alive for as long as the app runs —
    /// dropping the manager unregisters it.
    pub fn register(hotkey: HotKey) -> Result<Self, String> {
        let manager = GlobalHotKeyManager::new().map_err(|e| e.to_string())?;
        manager.register(hotkey).map_err(|e| e.to_string())?;
        Ok(Self {
            _manager: manager,
            id: hotkey.id(),
        })
    }

    /// Blocks the calling thread, invoking `on_press`/`on_release` as the
    /// registered key goes down and up. Intended to run on its own thread —
    /// see `lib.rs`.
    pub fn listen(&self, mut on_press: impl FnMut(), mut on_release: impl FnMut()) {
        let receiver = GlobalHotKeyEvent::receiver();
        loop {
            match receiver.recv() {
                Ok(event) if event.id == self.id => match event.state {
                    HotKeyState::Pressed => on_press(),
                    HotKeyState::Released => on_release(),
                },
                Ok(_) => {}
                Err(_) => break,
            }
        }
    }
}
