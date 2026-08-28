import { listen } from "@tauri-apps/api/event";

interface DictationStatus {
  phase: string;
  message: string;
}

const hud = document.querySelector<HTMLElement>(".hud");
const label = document.getElementById("hud-label");

void listen<DictationStatus>("dictation-status", ({ payload }) => {
  if (!hud || !label) return;
  hud.dataset.phase = payload.phase;
  label.textContent = payload.phase === "listening" ? "Listening…" : payload.message;
});
