import { invoke } from "@tauri-apps/api/core";

interface AccountView {
  email: string | null;
  status: string;
  isActive: boolean;
  usedSeconds: number | null;
  limitSeconds: number | null;
}

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const signedOutSection = $("signed-out");
const signedInSection = $("signed-in");
const requestStep = $("request-code-step");
const verifyStep = $("verify-code-step");
const signedOutStatus = $<HTMLParagraphElement>("signed-out-status");

const emailInput = $<HTMLInputElement>("email");
const codeInput = $<HTMLInputElement>("code");
const sendCodeButton = $<HTMLButtonElement>("send-code");
const verifyCodeButton = $<HTMLButtonElement>("verify-code");
const signOutButton = $<HTMLButtonElement>("sign-out");
const subscribeButton = $<HTMLButtonElement>("subscribe-monthly");

const accountEmail = $("account-email");
const accountSubStatus = $("account-subscription-status");
const usageRow = $("usage-row");
const usageBar = $<HTMLProgressElement>("usage-bar");
const usageText = $("usage-text");

let pendingEmail = "";

async function refresh() {
  const account = await invoke<AccountView | null>("account_status").catch(() => null);
  if (!account) {
    signedOutSection.hidden = false;
    signedInSection.hidden = true;
    return;
  }

  signedOutSection.hidden = true;
  signedInSection.hidden = false;
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
}

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
  await invoke("sign_out");
  await refresh();
});

subscribeButton.addEventListener("click", async () => {
  try {
    const url = await invoke<string>("subscribe", { annual: false });
    window.open(url, "_blank");
  } catch (e) {
    accountSubStatus.textContent = String(e);
  }
});

refresh();
// The checkout flow finishes in the browser — pick up the new subscription
// state without asking the user to close and reopen the window.
window.addEventListener("focus", refresh);
