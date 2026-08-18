mod audio;
mod cloud;
mod hotkey;
mod insertion;

use cloud::CloudClient;
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, State};

struct AppState {
    cloud: Arc<CloudClient>,
}

// MARK: - Frontend-facing commands (sign-in flow)

#[tauri::command]
async fn request_email_code(state: State<'_, AppState>, email: String) -> Result<(), String> {
    state
        .cloud
        .request_email_code(&email)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn verify_email_code(
    state: State<'_, AppState>,
    email: String,
    code: String,
) -> Result<(), String> {
    state
        .cloud
        .verify_email_code(&email, &code)
        .await
        .map_err(|e| e.to_string())
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct AccountView {
    email: Option<String>,
    status: String,
    is_active: bool,
    used_seconds: Option<u64>,
    limit_seconds: Option<u64>,
}

#[tauri::command]
async fn account_status(state: State<'_, AppState>) -> Result<Option<AccountView>, String> {
    if !state.cloud.is_signed_in() {
        return Ok(None);
    }
    let account = state
        .cloud
        .refresh_account()
        .await
        .map_err(|e| e.to_string())?;
    Ok(Some(AccountView {
        email: account.email.clone(),
        is_active: account.is_active(),
        status: account.status.clone(),
        used_seconds: account.usage.as_ref().map(|u| u.used_seconds),
        limit_seconds: account.usage.as_ref().map(|u| u.limit_seconds),
    }))
}

#[tauri::command]
fn sign_out(state: State<'_, AppState>) {
    let _ = &state;
    CloudClient::sign_out();
}

#[tauri::command]
async fn subscribe(state: State<'_, AppState>, annual: bool) -> Result<String, String> {
    state
        .cloud
        .checkout_url(annual)
        .await
        .map_err(|e| e.to_string())
}

// MARK: - Dictation pipeline

/// Runs record → transcribe → clean → paste for one push-to-talk cycle.
/// Best-effort at every stage past transcription: a cleanup failure falls
/// back to the raw transcript rather than losing the dictation, matching the
/// Mac client.
async fn finish_dictation(app: AppHandle, samples: Vec<f32>) {
    let state = app.state::<AppState>();
    let duration_seconds = samples.len() as f64 / audio::TARGET_SAMPLE_RATE as f64;
    if duration_seconds < 0.3 {
        return; // A stray tap, not a dictation.
    }
    let wav = audio::encode_wav(&samples, audio::TARGET_SAMPLE_RATE);

    let transcript = match state.cloud.transcribe(wav, duration_seconds, None, None).await {
        Ok(text) if !text.trim().is_empty() => text,
        Ok(_) => return, // Silence — nothing worth inserting.
        Err(e) => {
            eprintln!("transcription failed: {e}");
            return;
        }
    };

    // TODO: wire up a real vocabulary/dictionary setting before shipping —
    // this always sends no hint, so Polishing can't correct phonetic
    // mangling of names/jargon yet on Windows the way it does on Mac.
    let final_text = match state.cloud.cleanup(&transcript, None).await {
        Ok(cleaned) => cleaned,
        Err(e) => {
            eprintln!("cleanup failed, using raw transcript: {e}");
            transcript
        }
    };

    if let Err(e) = insertion::insert(&final_text) {
        eprintln!("insertion failed: {e}");
    }
}

fn start_hotkey_listener(app: AppHandle) {
    std::thread::spawn(move || {
        let hotkey = hotkey::default_hotkey();
        let registered = match hotkey::Hotkey::register(hotkey) {
            Ok(h) => h,
            Err(e) => {
                eprintln!("could not register push-to-talk hotkey: {e}");
                return;
            }
        };

        let app_for_press = app.clone();
        let app_for_release = app.clone();

        // A plain `RefCell`, not a `Mutex`: `Hotkey::listen` delivers press
        // and release on this one thread, one at a time, never concurrently
        // — and `cpal::Stream` isn't `Send` on every platform, so this must
        // never need to be. Keeping it off `AppState` (which Tauri requires
        // to be `Send + Sync`) is what makes that true.
        let active_recording: std::rc::Rc<std::cell::RefCell<Option<audio::Recording>>> =
            std::rc::Rc::new(std::cell::RefCell::new(None));
        let active_recording_release = std::rc::Rc::clone(&active_recording);

        registered.listen(
            move || {
                let mut slot = active_recording.borrow_mut();
                if slot.is_some() {
                    return; // Already recording — a stray repeat key-down.
                }
                match audio::Recording::start() {
                    Ok(r) => {
                        *slot = Some(r);
                        let _ = show_hud(&app_for_press);
                    }
                    Err(e) => eprintln!("could not start recording: {e}"),
                }
            },
            move || {
                let taken = active_recording_release.borrow_mut().take();
                let _ = hide_hud(&app_for_release);
                if let Some(recording) = taken {
                    let samples = recording.finish();
                    let app_for_task = app_for_release.clone();
                    tauri::async_runtime::spawn(finish_dictation(app_for_task, samples));
                }
            },
        );
    });
}

fn show_hud(app: &AppHandle) -> tauri::Result<()> {
    if let Some(hud) = app.get_webview_window("hud") {
        hud.show()?;
    }
    Ok(())
}

fn hide_hud(app: &AppHandle) -> tauri::Result<()> {
    if let Some(hud) = app.get_webview_window("hud") {
        hud.hide()?;
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            cloud: Arc::new(CloudClient::new()),
        })
        .invoke_handler(tauri::generate_handler![
            request_email_code,
            verify_email_code,
            account_status,
            sign_out,
            subscribe,
        ])
        .setup(|app| {
            let handle = app.handle().clone();

            let show_settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
            let quit = PredefinedMenuItem::quit(app, Some("Quit Plainsay"))?;
            let menu = Menu::with_items(app, &[&show_settings, &quit])?;

            TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .tooltip("Plainsay")
                .on_menu_event(move |app, event| {
                    if event.id() == "settings" {
                        if let Some(main) = app.get_webview_window("main") {
                            let _ = main.show();
                            let _ = main.set_focus();
                        }
                    }
                })
                .build(app)?;

            start_hotkey_listener(handle);
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
