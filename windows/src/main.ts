import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";

interface AccountView {
  email: string | null;
  status: string;
  isActive: boolean;
  usedSeconds: number | null;
  limitSeconds: number | null;
}

interface DictationStatus {
  phase: string;
  message: string;
  isError: boolean;
}

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const accountLoadingSection = $("account-loading");
const accountErrorSection = $("account-error");
const signedOutSection = $("signed-out");
const signedInSection = $("signed-in");
const requestStep = $("request-code-step");
const verifyStep = $("verify-code-step");
const accountErrorStatus = $<HTMLParagraphElement>("account-error-status");
const signedOutStatus = $<HTMLParagraphElement>("signed-out-status");
const dictationStatus = $<HTMLParagraphElement>("dictation-status");

const emailInput = $<HTMLInputElement>("email");
const codeInput = $<HTMLInputElement>("code");
const sendCodeButton = $<HTMLButtonElement>("send-code");
const verifyCodeButton = $<HTMLButtonElement>("verify-code");
const retryAccountButton = $<HTMLButtonElement>("retry-account");
const signOutButton = $<HTMLButtonElement>("sign-out");
const subscribeButton = $<HTMLButtonElement>("subscribe-monthly");

const accountEmail = $("account-email");
const accountSubStatus = $("account-subscription-status");
const usageRow = $("usage-row");
const usageBar = $<HTMLProgressElement>("usage-bar");
const usageText = $("usage-text");

let pendingEmail = "";
let refreshGeneration = 0;

const accountSections = [
  accountLoadingSection,
  accountErrorSection,
  signedOutSection,
  signedInSection,
];

function showAccountSection(section: HTMLElement) {
  for (const candidate of accountSections) {
    candidate.hidden = candidate !== section;
  }
}

function showDictationStatus(status: DictationStatus) {
  dictationStatus.textContent = status.message;
  dictationStatus.classList.toggle("status-error", status.isError);
  dictationStatus.dataset.phase = status.phase;
}

async function initializeDictationStatus() {
  let receivedEvent = false;
  try {
    await listen<DictationStatus>("dictation-status", (event) => {
      receivedEvent = true;
      showDictationStatus(event.payload);
    });
    const current = await invoke<DictationStatus>("dictation_status");
    if (!receivedEvent) showDictationStatus(current);
  } catch (error) {
    console.error("Failed to load dictation status", error);
  }
}

async function refresh() {
  const generation = ++refreshGeneration;
  showAccountSection(accountLoadingSection);
  retryAccountButton.disabled = true;

  try {
    const account = await invoke<AccountView | null>("account_status");
    if (generation !== refreshGeneration) return;

    if (!account) {
      showAccountSection(signedOutSection);
      return;
    }

    accountEmail.textContent = account.email ?? "Signed in";
    accountSubStatus.textContent = account.isActive
      ? `Subscription: ${account.status}`
      : "Not subscribed yet";
    subscribeButton.hidden = account.isActive;

    if (account.isActive && account.limitSeconds && account.limitSeconds > 0) {
      usageRow.hidden = false;
      usageBar.max = account.limitSeconds;
      usageBar.value = account.usedSeconds ?? 0;
      const usedMinutes = Math.round((account.usedSeconds ?? 0) / 60);
      const limitMinutes = Math.round(account.limitSeconds / 60);
      usageText.textContent = `${usedMinutes} of ${limitMinutes} minutes this month`;
    } else {
      usageRow.hidden = true;
    }

    showAccountSection(signedInSection);
  } catch (error) {
    if (generation !== refreshGeneration) return;

    console.error("Failed to load account status", error);
    accountErrorStatus.textContent =
      "We couldn't load your account. Check your connection and try again.";
    showAccountSection(accountErrorSection);
  } finally {
    if (generation === refreshGeneration) {
      retryAccountButton.disabled = false;
    }
  }
}

retryAccountButton.addEventListener("click", refresh);

sendCodeButton.addEventListener("click", async () => {
  const email = emailInput.value.trim();
  if (!email.includes("@")) return;
  sendCodeButton.disabled = true;
  signedOutStatus.textContent = "";
  try {
    await invoke("request_email_code", { email });
    pendingEmail = email;
    requestStep.hidden = true;
    verifyStep.hidden = false;
    signedOutStatus.textContent = "Code sent. Check your email.";
  } catch (e) {
    signedOutStatus.textContent = String(e);
  } finally {
    sendCodeButton.disabled = false;
  }
});

verifyCodeButton.addEventListener("click", async () => {
  const code = codeInput.value.trim();
  if (code.length < 6) return;
  verifyCodeButton.disabled = true;
  signedOutStatus.textContent = "";
  try {
    await invoke("verify_email_code", { email: pendingEmail, code });
    requestStep.hidden = false;
    verifyStep.hidden = true;
    codeInput.value = "";
    await refresh();
  } catch (e) {
    signedOutStatus.textContent = String(e);
  } finally {
    verifyCodeButton.disabled = false;
  }
});

signOutButton.addEventListener("click", async () => {
  signOutButton.disabled = true;
  try {
    await invoke("sign_out");
    await refresh();
  } catch (error) {
    accountSubStatus.textContent = `Could not sign out: ${String(error)}`;
  } finally {
    signOutButton.disabled = false;
  }
});

subscribeButton.addEventListener("click", async () => {
  try {
    const url = await invoke<string>("subscribe", { annual: false });
    await openUrl(url);
  } catch (e) {
    accountSubStatus.textContent = String(e);
  }
});

void initializeDictationStatus();
void refresh();
// The checkout flow finishes in the browser — pick up the new subscription
// state without asking the user to close and reopen the window.
window.addEventListener("focus", () => void refresh());
