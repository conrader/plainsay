/* Non-Mac download notice. No cookies, storage, or third-party code. */
(() => {
  'use strict';

  const api = 'https://api.plainsay.app';
  const platforms = ['windows', 'linux', 'android', 'ios', 'chromeos'];

  function detectPlatform() {
    const forced = new URLSearchParams(location.search).get('platform');
    if (platforms.includes(forced) || forced === 'other' || forced === 'macos') return forced;
    const ua = navigator.userAgent || '';
    const macUA = /Macintosh|Mac OS X/i.test(ua);
    if (/iPhone|iPad|iPod/i.test(ua) || (macUA && navigator.maxTouchPoints > 1)) return 'ios';
    if (/Android/i.test(ua)) return 'android';
    if (navigator.userAgentData?.platform === 'macOS' || macUA) return 'macos';
    const hints = { Windows: 'windows', Linux: 'linux', Android: 'android', 'Chrome OS': 'chromeos' };
    const hinted = hints[navigator.userAgentData?.platform];
    if (hinted) return hinted;
    if (/Windows/i.test(ua)) return 'windows';
    if (/CrOS/i.test(ua)) return 'chromeos';
    if (/Linux/i.test(ua)) return 'linux';
    return 'other';
  }

  const platform = detectPlatform();
  // Unknown devices keep the normal link, as do Macs. No listeners or beacons.
  if (!platforms.includes(platform)) return;

  const translations = {
    en: {
      heading: 'Plainsay is a Mac app',
      intro: 'Plainsay is a Mac app (Apple silicon, macOS 14+).',
      unavailable: ["It won't run on Windows yet.", "It won't run on Linux yet.", "It won't run on Android yet.", "It won't run on iOS yet.", "It won't run on ChromeOS yet.", "It won't run on this device yet."],
      label: "Tell me when there's a Windows version", submit: 'Notify me', close: 'Close',
      anyway: 'Download the Mac version anyway', success: "Thanks — we'll email you once.",
      error: 'Something went wrong. Email', errorEnd: 'instead.',
      privacy: 'We only store your email to send that one message.',
    },
    de: {
      heading: 'Plainsay ist eine Mac-App',
      intro: 'Plainsay ist eine Mac-App (Apple silicon, macOS 14+).',
      unavailable: ['Unter Windows läuft sie noch nicht.', 'Unter Linux läuft sie noch nicht.', 'Unter Android läuft sie noch nicht.', 'Unter iOS läuft sie noch nicht.', 'Unter ChromeOS läuft sie noch nicht.', 'Auf diesem Gerät läuft sie noch nicht.'],
      label: 'Sag mir Bescheid, wenn es eine Windows-Version gibt', submit: 'Benachrichtigen', close: 'Schließen',
      anyway: 'Mac-Version trotzdem herunterladen', success: 'Danke — wir schicken dir einmal eine E-Mail.',
      error: 'Etwas ist schiefgelaufen. Schreib stattdessen an', errorEnd: '.',
      privacy: 'Wir speichern nur deine E-Mail-Adresse, um diese eine Nachricht zu senden.',
    },
    es: {
      heading: 'Plainsay es una app para Mac',
      intro: 'Plainsay es una app para Mac (Apple silicon, macOS 14+).',
      unavailable: ['Todavía no funciona en Windows.', 'Todavía no funciona en Linux.', 'Todavía no funciona en Android.', 'Todavía no funciona en iOS.', 'Todavía no funciona en ChromeOS.', 'Todavía no funciona en este dispositivo.'],
      label: 'Avísame cuando haya una versión para Windows', submit: 'Avisarme', close: 'Cerrar',
      anyway: 'Descargar la versión para Mac de todos modos', success: 'Gracias — te enviaremos un solo correo.',
      error: 'Algo ha salido mal. Escribe a', errorEnd: 'para avisarnos.',
      privacy: 'Solo guardamos tu correo electrónico para enviarte ese único mensaje.',
    },
    fr: {
      heading: 'Plainsay est une app pour Mac',
      intro: 'Plainsay est une app pour Mac (Apple silicon, macOS 14+).',
      unavailable: ['Elle ne fonctionne pas encore sous Windows.', 'Elle ne fonctionne pas encore sous Linux.', 'Elle ne fonctionne pas encore sur Android.', 'Elle ne fonctionne pas encore sur iOS.', 'Elle ne fonctionne pas encore sous ChromeOS.', 'Elle ne fonctionne pas encore sur cet appareil.'],
      label: 'Prévenez-moi quand une version Windows sera disponible', submit: 'Me prévenir', close: 'Fermer',
      anyway: 'Télécharger quand même la version Mac', success: 'Merci — nous vous enverrons un seul e-mail.',
      error: 'Une erreur est survenue. Écrivez plutôt à', errorEnd: '.',
      privacy: 'Nous conservons uniquement votre e-mail pour envoyer ce seul message.',
    },
    it: {
      heading: 'Plainsay è un’app per Mac',
      intro: 'Plainsay è un’app per Mac (Apple silicon, macOS 14+).',
      unavailable: ['Non funziona ancora su Windows.', 'Non funziona ancora su Linux.', 'Non funziona ancora su Android.', 'Non funziona ancora su iOS.', 'Non funziona ancora su ChromeOS.', 'Non funziona ancora su questo dispositivo.'],
      label: 'Avvisami quando sarà disponibile una versione per Windows', submit: 'Avvisami', close: 'Chiudi',
      anyway: 'Scarica comunque la versione per Mac', success: 'Grazie — ti invieremo una sola email.',
      error: 'Qualcosa è andato storto. Scrivi invece a', errorEnd: '.',
      privacy: 'Conserviamo solo la tua email per inviarti quell’unico messaggio.',
    },
    ja: {
      heading: 'PlainsayはMac用アプリです',
      intro: 'PlainsayはMac用アプリです（Apple silicon、macOS 14以降）。',
      unavailable: ['Windowsにはまだ対応していません。', 'Linuxにはまだ対応していません。', 'Androidにはまだ対応していません。', 'iOSにはまだ対応していません。', 'ChromeOSにはまだ対応していません。', 'このデバイスにはまだ対応していません。'],
      label: 'Windows版が公開されたら知らせてほしい', submit: '通知を受け取る', close: '閉じる',
      anyway: 'それでもMac版をダウンロードする', success: 'ありがとうございます。公開時に一度だけメールでお知らせします。',
      error: 'エラーが発生しました。代わりに', errorEnd: 'までメールをお送りください。',
      privacy: 'この一度の通知を送るために、メールアドレスのみを保存します。',
    },
    ko: {
      heading: 'Plainsay는 Mac용 앱입니다',
      intro: 'Plainsay는 Mac용 앱입니다(Apple silicon, macOS 14 이상).',
      unavailable: ['아직 Windows에서는 실행되지 않습니다.', '아직 Linux에서는 실행되지 않습니다.', '아직 Android에서는 실행되지 않습니다.', '아직 iOS에서는 실행되지 않습니다.', '아직 ChromeOS에서는 실행되지 않습니다.', '아직 이 기기에서는 실행되지 않습니다.'],
      label: 'Windows 버전이 나오면 알려 주세요', submit: '알림 받기', close: '닫기',
      anyway: '그래도 Mac 버전 다운로드', success: '감사합니다. 출시되면 이메일을 한 번만 보내 드릴게요.',
      error: '문제가 발생했습니다. 대신', errorEnd: '으로 이메일을 보내 주세요.',
      privacy: '이 알림 한 번을 보내기 위해 이메일 주소만 저장합니다.',
    },
    nl: {
      heading: 'Plainsay is een Mac-app',
      intro: 'Plainsay is een Mac-app (Apple silicon, macOS 14+).',
      unavailable: ['De app werkt nog niet op Windows.', 'De app werkt nog niet op Linux.', 'De app werkt nog niet op Android.', 'De app werkt nog niet op iOS.', 'De app werkt nog niet op ChromeOS.', 'De app werkt nog niet op dit apparaat.'],
      label: 'Laat me weten wanneer er een Windows-versie is', submit: 'Houd me op de hoogte', close: 'Sluiten',
      anyway: 'Toch de Mac-versie downloaden', success: 'Bedankt — we sturen je één e-mail.',
      error: 'Er ging iets mis. Mail in plaats daarvan naar', errorEnd: '.',
      privacy: 'We bewaren alleen je e-mailadres om dat ene bericht te sturen.',
    },
    pl: {
      heading: 'Plainsay to aplikacja na Maca',
      intro: 'Plainsay to aplikacja na Maca (Apple silicon, macOS 14+).',
      unavailable: ['Na Windowsie jeszcze nie działa.', 'Na Linuksie jeszcze nie działa.', 'Na Androidzie jeszcze nie działa.', 'Na iOS jeszcze nie działa.', 'Na ChromeOS jeszcze nie działa.', 'Na tym urządzeniu jeszcze nie działa.'],
      label: 'Daj mi znać, gdy pojawi się wersja na Windows', submit: 'Powiadom mnie', close: 'Zamknij',
      anyway: 'Pobierz mimo to wersję na Maca', success: 'Dzięki — napiszemy do Ciebie raz, gdy będzie gotowa.',
      error: 'Coś poszło nie tak. Napisz zamiast tego na', errorEnd: '.',
      privacy: 'Zapisujemy tylko Twój e-mail, żeby wysłać tę jedną wiadomość.',
    },
    pt: {
      heading: 'O Plainsay é uma aplicação para Mac',
      intro: 'O Plainsay é uma aplicação para Mac (Apple silicon, macOS 14+).',
      unavailable: ['Ainda não funciona no Windows.', 'Ainda não funciona no Linux.', 'Ainda não funciona no Android.', 'Ainda não funciona no iOS.', 'Ainda não funciona no ChromeOS.', 'Ainda não funciona neste dispositivo.'],
      label: 'Avise-me quando houver uma versão para Windows', submit: 'Avisar-me', close: 'Fechar',
      anyway: 'Descarregar a versão para Mac mesmo assim', success: 'Obrigado — enviaremos apenas um e-mail.',
      error: 'Ocorreu um erro. Escreva para', errorEnd: 'em alternativa.',
      privacy: 'Guardamos apenas o seu e-mail para enviar essa única mensagem.',
    },
    ru: {
      heading: 'Plainsay — приложение для Mac',
      intro: 'Plainsay — приложение для Mac (Apple silicon, macOS 14+).',
      unavailable: ['На Windows оно пока не работает.', 'На Linux оно пока не работает.', 'На Android оно пока не работает.', 'На iOS оно пока не работает.', 'На ChromeOS оно пока не работает.', 'На этом устройстве оно пока не работает.'],
      label: 'Сообщите мне, когда появится версия для Windows', submit: 'Уведомить меня', close: 'Закрыть',
      anyway: 'Всё равно скачать версию для Mac', success: 'Спасибо — мы отправим вам только одно письмо.',
      error: 'Что-то пошло не так. Напишите на', errorEnd: '.',
      privacy: 'Мы храним только ваш e-mail, чтобы отправить это единственное письмо.',
    },
    uk: {
      heading: 'Plainsay — застосунок для Mac',
      intro: 'Plainsay — застосунок для Mac (Apple silicon, macOS 14+).',
      unavailable: ['На Windows він поки не працює.', 'На Linux він поки не працює.', 'На Android він поки не працює.', 'На iOS він поки не працює.', 'На ChromeOS він поки не працює.', 'На цьому пристрої він поки не працює.'],
      label: 'Повідомте мене, коли з’явиться версія для Windows', submit: 'Повідомити мене', close: 'Закрити',
      anyway: 'Усе одно завантажити версію для Mac', success: 'Дякуємо — ми надішлемо вам лише один лист.',
      error: 'Щось пішло не так. Напишіть на', errorEnd: '.',
      privacy: 'Ми зберігаємо лише вашу електронну адресу, щоб надіслати цей один лист.',
    },
    zh: {
      heading: 'Plainsay 是一款 Mac 应用',
      intro: 'Plainsay 是一款 Mac 应用（Apple silicon，macOS 14 及以上）。',
      unavailable: ['目前还不能在 Windows 上运行。', '目前还不能在 Linux 上运行。', '目前还不能在 Android 上运行。', '目前还不能在 iOS 上运行。', '目前还不能在 ChromeOS 上运行。', '目前还不能在此设备上运行。'],
      label: 'Windows 版推出时通知我', submit: '通知我', close: '关闭',
      anyway: '仍然下载 Mac 版', success: '谢谢 — 我们只会给你发送一次邮件。',
      error: '出了点问题。请改为发送邮件至', errorEnd: '。',
      privacy: '我们只保存你的邮箱地址，用于发送这一次通知。',
    },
  };

  const pageLang = document.documentElement.lang || 'en';
  const lang = pageLang.toLowerCase().split('-')[0];
  const strings = translations[lang] || translations.en;

  function beacon(event) {
    fetch(`${api}/r/non-mac?e=${event}`, { mode: 'no-cors', keepalive: true, credentials: 'omit' }).catch(() => {});
  }

  let dialog, overlay, email, website, submit, status, anyway, returnFocus;
  let nativeDialog = false;
  let active = false;
  let savedOverflow;
  let inertElements = [];

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text) node.textContent = text;
    return node;
  }

  function restorePage() {
    if (!active) return;
    active = false;
    document.body.style.overflow = savedOverflow;
    inertElements.forEach(([node, value]) => { node.inert = value; });
    inertElements = [];
    if (returnFocus?.isConnected) returnFocus.focus({ preventScroll: true });
  }

  function closeNotice() {
    if (nativeDialog) dialog.close();
    else overlay.hidden = true;
    restorePage();
  }

  function buildDialog() {
    const style = element('style');
    style.textContent = `
      .pn-dialog,.pn-dialog *{box-sizing:border-box}
      .pn-dialog{color-scheme:light;background:#fffefa;color:#202721;border:1px solid #d8dbd1;border-radius:16px;padding:32px;width:calc(100% - 32px);max-width:480px;max-height:calc(100vh - 32px);max-height:calc(100dvh - 32px);overflow:auto;box-shadow:0 24px 80px #0004;font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;text-align:left;letter-spacing:normal}
      .pn-dialog::backdrop{background:#14161aaa}
      .pn-backdrop{position:fixed;inset:0;z-index:2147483647;background:#14161aaa;display:flex;align-items:center;justify-content:center;padding:16px;overflow:auto}
      .pn-backdrop[hidden]{display:none}
      .pn-backdrop .pn-dialog{width:100%;margin:auto}
      .pn-dialog .pn-header{display:flex;align-items:start;gap:16px;margin-bottom:16px}
      .pn-dialog .pn-heading{font:600 26px/1.2 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#202721;letter-spacing:-.02em;margin:0;flex:1}
      .pn-dialog .pn-close{font:inherit;line-height:1;background:none;border:0;border-radius:4px;color:#62675e;cursor:pointer;padding:6px;min-width:36px;min-height:36px;margin:-6px -6px 0 0}
      .pn-dialog .pn-text{font:inherit;color:#62675e;margin:0 0 24px;max-width:none}
      .pn-dialog .pn-label{display:block;font:600 15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#202721;margin:0 0 8px}
      .pn-dialog .pn-email{font:inherit;background:#fff;color:#202721;border:1px solid #92998c;border-radius:7px;padding:11px 12px;min-width:0;width:100%;margin:0 0 12px}
      .pn-dialog .pn-submit{font:600 15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#254d3e;color:#fff;border:1px solid #254d3e;border-radius:7px;padding:12px 18px;cursor:pointer;width:100%}
      .pn-dialog .pn-submit:disabled{opacity:.65;cursor:wait}
      .pn-dialog .pn-status{font:inherit;font-size:14px;color:#254d3e;margin:12px 0 0;max-width:none}
      .pn-dialog .pn-status.pn-error{color:#923c25}
      .pn-dialog .pn-anyway{display:inline-block;margin:24px 0 12px;font:inherit;font-size:14px}
      .pn-dialog a{color:#254d3e;text-decoration:underline;text-underline-offset:3px}
      .pn-dialog .pn-privacy{font:inherit;font-size:12px;color:#62675e;margin:0;max-width:none}
      .pn-dialog :is(a,button,input):focus-visible{outline:3px solid #af632c;outline-offset:3px}
      .pn-dialog .pn-honeypot{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);clip-path:inset(50%);white-space:nowrap;border:0}
      @media(max-width:480px){.pn-dialog{padding:24px}.pn-dialog .pn-heading{font-size:23px}}
    `;
    document.head.append(style);
    const candidate = document.createElement('dialog');
    nativeDialog = typeof candidate.showModal === 'function';
    dialog = nativeDialog ? candidate : element('div');
    dialog.className = 'pn-dialog';
    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-modal', 'true');
    dialog.setAttribute('aria-labelledby', 'pn-heading');
    dialog.setAttribute('aria-describedby', 'pn-description');
    const header = element('div', 'pn-header');
    const heading = element('h2', 'pn-heading', strings.heading);
    heading.id = 'pn-heading';
    const close = element('button', 'pn-close', '×');
    close.type = 'button';
    close.setAttribute('aria-label', strings.close);
    close.addEventListener('click', closeNotice);
    header.append(heading, close);
    const description = element('p', 'pn-text', `${strings.intro} ${strings.unavailable[platforms.indexOf(platform)]}`);
    description.id = 'pn-description';
    const form = element('form');
    const label = element('label', 'pn-label', strings.label);
    label.htmlFor = 'pn-email';
    email = element('input', 'pn-email');
    email.id = 'pn-email';
    email.name = 'email';
    email.type = 'email';
    email.required = true;
    email.autocomplete = 'email';
    email.maxLength = 254;
    const trap = element('div', 'pn-honeypot');
    trap.setAttribute('aria-hidden', 'true');
    website = element('input');
    website.type = 'text';
    website.name = 'website';
    website.tabIndex = -1;
    website.autocomplete = 'off';
    website.setAttribute('aria-hidden', 'true');
    trap.append(website);
    submit = element('button', 'pn-submit', strings.submit);
    submit.type = 'submit';
    status = element('p', 'pn-status');
    status.setAttribute('aria-live', 'polite');
    status.setAttribute('aria-atomic', 'true');
    form.append(label, email, trap, submit, status);
    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      if (submit.disabled) return;
      submit.disabled = true;
      form.setAttribute('aria-busy', 'true');
      status.textContent = '';
      status.classList.remove('pn-error');
      try {
        const response = await fetch(`${api}/v1/waitlist`, {
          method: 'POST', credentials: 'omit', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email: email.value, platform, lang: translations[lang] ? lang : 'en', website: website.value }),
        });
        if (!response.ok || (await response.json()).ok !== true) throw new Error('Signup failed');
        status.textContent = strings.success;
      } catch {
        status.classList.add('pn-error');
        const contact = element('a', '', 'hi@plainsay.app');
        contact.href = 'mailto:hi@plainsay.app';
        const end = /^[.。]/.test(strings.errorEnd) ? strings.errorEnd : ` ${strings.errorEnd}`;
        status.replaceChildren(`${strings.error} `, contact, end);
      } finally {
        submit.disabled = false;
        form.removeAttribute('aria-busy');
      }
    });
    anyway = element('a', 'pn-anyway', strings.anyway);
    anyway.setAttribute('data-pn-anyway', '');
    dialog.append(header, description, form, anyway, element('p', 'pn-privacy', strings.privacy));
    if (nativeDialog) {
      document.body.append(dialog);
      dialog.addEventListener('cancel', (event) => { event.preventDefault(); closeNotice(); });
      dialog.addEventListener('close', restorePage);
    } else {
      overlay = element('div', 'pn-backdrop');
      overlay.hidden = true;
      overlay.append(dialog);
      document.body.append(overlay);
    }
    // Also trap focus in the fallback on browsers without native modal support.
    document.addEventListener('focusin', (event) => {
      if (active && !nativeDialog && !dialog.contains(event.target)) email.focus();
    });
    dialog.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') { event.preventDefault(); closeNotice(); }
      if (event.key !== 'Tab') return;
      const items = Array.from(dialog.querySelectorAll('button:not(:disabled), input:not([tabindex="-1"]), a[href]'));
      const first = items[0], last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    });
  }

  function showNotice(link) {
    if (!dialog) buildDialog();
    returnFocus = link;
    anyway.href = link.href;
    if (active) return;
    savedOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    if (nativeDialog) dialog.showModal();
    else {
      inertElements = Array.from(document.body.children).filter((node) => node !== overlay)
        .map((node) => [node, node.inert]);
      inertElements.forEach(([node]) => { node.inert = true; });
      overlay.hidden = false;
    }
    active = true;
    email.focus();
  }

  function handleDownload(event) {
    if (event.type === 'auxclick' && event.button !== 1) return;
    const link = event.target instanceof Element ? event.target.closest('a[href*="Plainsay-latest.dmg"]') : null;
    if (!link) return;
    if (link.hasAttribute('data-pn-anyway')) { beacon('anyway'); return; }
    event.preventDefault();
    event.stopImmediatePropagation();
    beacon('intercept');
    showNotice(link);
  }
  document.addEventListener('click', handleDownload, true);
  document.addEventListener('auxclick', handleDownload, true);
})();
