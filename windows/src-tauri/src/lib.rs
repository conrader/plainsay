mod audio;
mod cloud;
mod hotkey;
mod insertion;

use cloud::CloudClient;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct DictationStatus {
    phase: String,
    message: String,
    is_error: bool,
}

impl DictationStatus {
    fn ready() -> Self {
        Self {
            phase: "ready".to_string(),
            message: "Hold Right Ctrl to dictate.".to_string(),
            is_error: false,
        }
    }

    fn signed_out() -> Self {
        Self {
            phase: "signed-out".to_string(),
            message: "Sign in to use Plainsay Cloud.".to_string(),
            is_error: false,
        }
    }

    fn startup_error(message: impl Into<String>) -> Self {
        Self {
            phase: "error".to_string(),
            message: message.into(),
            is_error: true,
        }
    }
}

struct AppState {
    cloud: Arc<CloudClient>,
    pipeline_busy: AtomicBool,
    status: Mutex<DictationStatus>,
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
    app: AppHandle,
    state: State<'_, AppState>,
    email: String,
    code: String,
) -> Result<(), String> {
    if state
        .pipeline_busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err("Wait for the current Plainsay operation to finish".to_string());
    }
    let _guard = PipelineGuard { app: app.clone() };
    state
        .cloud
        .verify_email_code(&email, &code)
        .await
        .map_err(|e| e.to_string())?;
    update_status(&app, "ready", "Hold Right Ctrl to dictate.", false);
    Ok(())
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
async fn account_status(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Option<AccountView>, String> {
    if !state.cloud.is_signed_in().map_err(|e| e.to_string())? {
        return Ok(None);
    }
    let account = match state.cloud.refresh_account().await {
        Ok(account) => account,
        Err(cloud::CloudError::NotSignedIn) => {
            update_status(&app, "signed-out", "Sign in to use Plainsay Cloud.", false);
            return Ok(None);
        }
        Err(error) => return Err(error.to_string()),
    };
    Ok(Some(AccountView {
        email: account.email.clone(),
        is_active: account.is_active(),
        status: account.status.clone(),
        used_seconds: account.usage.as_ref().map(|u| u.used_seconds),
        limit_seconds: account.usage.as_ref().map(|u| u.limit_seconds),
    }))
}

#[tauri::command]
async fn sign_out(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    if state
        .pipeline_busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err("Wait for the current dictation to finish before signing out".to_string());
    }
    let _guard = PipelineGuard { app: app.clone() };
    state.cloud.sign_out().await.map_err(|e| e.to_string())?;
    update_status(&app, "signed-out", "Sign in to use Plainsay Cloud.", false);
    Ok(())
}

#[tauri::command]
async fn subscribe(state: State<'_, AppState>, annual: bool) -> Result<String, String> {
    state
        .cloud
        .checkout_url(annual)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn dictation_status(state: State<'_, AppState>) -> Result<DictationStatus, String> {
    state
        .status
        .lock()
        .map(|status| status.clone())
        .map_err(|_| "Could not read dictation status".to_string())
}

// MARK: - Dictation pipeline

fn update_status(app: &AppHandle, phase: &str, message: impl Into<String>, is_error: bool) {
    let status = DictationStatus {
        phase: phase.to_string(),
        message: message.into(),
        is_error,
    };
    if let Ok(mut current) = app.state::<AppState>().status.lock() {
        *current = status.clone();
    }
    let _ = app.emit("dictation-status", status);
}

fn report_error(app: &AppHandle, message: impl Into<String>) {
    update_status(app, "error", message, true);
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.show();
        let _ = main.set_focus();
    }
}

struct PipelineGuard {
    app: AppHandle,
}

impl Drop for PipelineGuard {
    fn drop(&mut self) {
        self.app
            .state::<AppState>()
            .pipeline_busy
            .store(false, Ordering::Release);
        let _ = hide_hud(&self.app);
    }
}

/// Runs record → transcribe → clean → paste for one push-to-talk cycle.
/// Best-effort at every stage past transcription: a cleanup failure falls
/// back to the raw transcript rather than losing the dictation, matching the
/// Mac client.
async fn finish_dictation(
    app: AppHandle,
    samples: Vec<f32>,
    target: Option<insertion::InsertionTarget>,
) {
    let _guard = PipelineGuard { app: app.clone() };
    let cloud = Arc::clone(&app.state::<AppState>().cloud);
    let duration_seconds = samples.len() as f64 / audio::TARGET_SAMPLE_RATE as f64;
    if duration_seconds < 0.3 {
        update_status(&app, "ready", "Hold Right Ctrl to dictate.", false);
        return; // A stray tap, not a dictation.
    }
    update_status(&app, "processing", "Preparing audio…", false);
    let encoded = tauri::async_runtime::spawn_blocking(move || {
        audio::encode_m4a(&samples, audio::TARGET_SAMPLE_RATE)
    })
    .await;
    let audio = match encoded {
        Ok(Ok(audio)) => audio,
        Ok(Err(error)) => {
            report_error(&app, format!("Could not prepare the recording: {error}"));
            return;
        }
        Err(error) => {
            report_error(
                &app,
                format!("Audio preparation stopped unexpectedly: {error}"),
            );
            return;
        }
    };

    update_status(&app, "processing", "Transcribing…", false);
    let raw_transcript = match cloud.transcribe(audio, duration_seconds, None, None).await {
        Ok(text) => text,
        Err(error) => {
            report_error(&app, format!("Transcription failed: {error}"));
            return;
        }
    };
    let transcript = cloud::normalize_transcript(&raw_transcript);
    if transcript.is_empty() {
        update_status(
            &app,
            "ready",
            "No speech detected. Hold Right Ctrl to try again.",
            false,
        );
        return;
    }

    // TODO: wire up a real vocabulary/dictionary setting before shipping —
    // this always sends no hint, so Polishing can't correct phonetic
    // mangling of names/jargon yet on Windows the way it does on Mac.
    update_status(&app, "processing", "Polishing…", false);
    let (final_text, cleanup_failed) = match cloud.cleanup(&transcript, None).await {
        Ok(cleaned) => (cleaned, false),
        Err(error) => {
            eprintln!("cleanup failed, using raw transcript: {error}");
            (transcript, true)
        }
    };

    update_status(&app, "processing", "Inserting…", false);
    let insertion =
        tauri::async_runtime::spawn_blocking(move || insertion::insert(&final_text, target)).await;
    match insertion {
        Ok(Ok(())) => {}
        Ok(Err(error)) => {
            let message = if error.transcript_is_on_clipboard() {
                format!("Could not paste the dictation. It is still on the clipboard: {error}")
            } else {
                format!("Could not copy or paste the dictation: {error}")
            };
            report_error(&app, message);
            return;
        }
        Err(error) => {
            report_error(
                &app,
                format!("Text insertion stopped unexpectedly: {error}"),
            );
            return;
        }
    }

    let message = if cleanup_failed {
        "Inserted without Polishing. Hold Right Ctrl to dictate."
    } else {
        "Ready — hold Right Ctrl to dictate."
    };
    update_status(&app, "ready", message, false);
}

type ActiveRecording = (audio::Recording, Option<insertion::InsertionTarget>);

fn ask_user_to_sign_in(app: &AppHandle) {
    update_status(app, "signed-out", "Sign in to use Plainsay Cloud.", false);
    if let Some(main) = app.get_webview_window("main") {
        let _ = main.show();
        let _ = main.set_focus();
    }
}

fn begin_recording(
    app: &AppHandle,
    active_recording: &mut Option<ActiveRecording>,
    awaiting_release: &mut bool,
) {
    if active_recording.is_some() {
        return;
    }

    let state = app.state::<AppState>();
    match state.cloud.is_signed_in() {
        Ok(true) => {}
        Ok(false) => {
            *awaiting_release = true;
            ask_user_to_sign_in(app);
            return;
        }
        Err(error) => {
            *awaiting_release = true;
            report_error(
                app,
                format!("Could not read the saved Cloud session: {error}"),
            );
            return;
        }
    }
    if state
        .pipeline_busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        *awaiting_release = true;
        return;
    }

    let target = insertion::capture_target();
    match audio::Recording::start() {
        Ok(recording) => {
            *active_recording = Some((recording, target));
            update_status(app, "listening", "Listening…", false);
            if let Err(error) = show_hud(app) {
                eprintln!("could not show recording HUD: {error}");
            }
        }
        Err(error) => {
            state.pipeline_busy.store(false, Ordering::Release);
            *awaiting_release = true;
            report_error(app, format!("Could not start the microphone: {error}"));
        }
    }
}

fn finish_active_recording(
    app: &AppHandle,
    active_recording: &mut Option<ActiveRecording>,
    reached_limit: bool,
) {
    if let Some((recording, target)) = active_recording.take() {
        let message = if reached_limit {
            "10-minute recording limit reached. Processing…"
        } else {
            "Processing…"
        };
        update_status(app, "processing", message, false);
        let samples = recording.finish();
        tauri::async_runtime::spawn(finish_dictation(app.clone(), samples, target));
    }
}

fn abort_active_recording(
    app: &AppHandle,
    active_recording: &mut Option<ActiveRecording>,
    message: String,
) {
    // Only the recording owns this busy flag. A hook failure can also arrive
    // after key-up while the async pipeline (or an auth command) owns it; in
    // that case clearing it here would allow a second operation to race.
    if active_recording.take().is_some() {
        app.state::<AppState>()
            .pipeline_busy
            .store(false, Ordering::Release);
        let _ = hide_hud(app);
    }
    report_error(app, message);
}

fn start_hotkey_listener(app: AppHandle) {
    let app_for_error = app.clone();
    let spawn_result = std::thread::Builder::new()
        .name("plainsay-hotkey-dispatch".to_string())
        .spawn(move || {
            let events = match hotkey::start() {
                Ok(events) => events,
                Err(error) => {
                    report_error(&app, format!("Right Ctrl is unavailable: {error}"));
                    return;
                }
            };
            let mut active_recording: Option<ActiveRecording> = None;
            let mut awaiting_release = false;

            loop {
                match events.recv_timeout(std::time::Duration::from_millis(100)) {
                    Ok(Ok(hotkey::HotkeyEvent::Pressed)) => {
                        begin_recording(&app, &mut active_recording, &mut awaiting_release);
                    }
                    Ok(Ok(hotkey::HotkeyEvent::Released)) => {
                        awaiting_release = false;
                        finish_active_recording(&app, &mut active_recording, false);
                    }
                    Ok(Err(error)) => {
                        abort_active_recording(
                            &app,
                            &mut active_recording,
                            format!("Right Ctrl is unavailable: {error}"),
                        );
                        break;
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                        abort_active_recording(
                            &app,
                            &mut active_recording,
                            "The Right Ctrl listener stopped unexpectedly".to_string(),
                        );
                        break;
                    }
                }

                let pressed = hotkey::is_pressed();
                let capture_status = active_recording
                    .as_ref()
                    .map(|(recording, _)| recording.status());
                match capture_status {
                    Some(audio::CaptureStatus::LimitReached) => {
                        finish_active_recording(&app, &mut active_recording, true);
                        awaiting_release = pressed;
                    }
                    Some(audio::CaptureStatus::Failed(error)) => {
                        abort_active_recording(
                            &app,
                            &mut active_recording,
                            format!("The microphone stopped recording: {error}"),
                        );
                        awaiting_release = pressed;
                    }
                    Some(audio::CaptureStatus::Capturing) | None => {}
                }

                // The physical key state reconciles the bounded hook queue.
                // If Windows ever drops a queued edge, a release cannot leave
                // a recording stuck and a press is recovered on the next tick.
                if !pressed {
                    awaiting_release = false;
                    finish_active_recording(&app, &mut active_recording, false);
                } else if active_recording.is_none() && !awaiting_release {
                    begin_recording(&app, &mut active_recording, &mut awaiting_release);
                }
            }
        });

    if let Err(error) = spawn_result {
        report_error(
            &app_for_error,
            format!("Could not start the Right Ctrl listener: {error}"),
        );
    }
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
    let cloud = Arc::new(CloudClient::new());
    let initial_status = match cloud.is_signed_in() {
        Ok(true) => DictationStatus::ready(),
        Ok(false) => DictationStatus::signed_out(),
        Err(error) => DictationStatus::startup_error(format!(
            "Could not read the saved Cloud session: {error}"
        )),
    };
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            cloud,
            pipeline_busy: AtomicBool::new(false),
            status: Mutex::new(initial_status),
        })
        .invoke_handler(tauri::generate_handler![
            request_email_code,
            verify_email_code,
            account_status,
            sign_out,
            subscribe,
            dictation_status,
        ])
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .setup(|app| {
            let handle = app.handle().clone();

            if let Some(hud) = app.get_webview_window("hud") {
                hud.set_ignore_cursor_events(true)?;
            }

            let show_settings =
                MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
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
