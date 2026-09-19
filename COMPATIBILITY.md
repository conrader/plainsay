# Dictating into Mac apps

Which apps Plainsay has actually been observed working in, and what to do when
one of them misbehaves.

**Read the dates and versions before trusting a row.** A row says what happened
on one Mac, with one app version, in one field. It is evidence, not a promise.
macOS 26 apps change their text fields between releases, and a field that
accepts a paste today can stop tomorrow.

## How insertion works, and what happens when it fails

Plainsay does not type your dictation key by key. It **writes the text to the
pasteboard and synthesises ⌘V**, then restores whatever was on the pasteboard
before. That is the only method that works in every kind of text field on
macOS, including web pages and Electron apps, where synthetic keystrokes are
unreliable.

Three consequences worth knowing:

- **Your clipboard is borrowed, not taken.** Plainsay snapshots every
  pasteboard item first and puts it back afterwards. If Plainsay is killed in
  the half-second between the two, the clipboard keeps the dictation.
- **If nothing is focused, there is nothing to paste into.** The dictation is
  left on the clipboard and the HUD says so — press ⌘V wherever you actually
  meant it to go. Nothing is lost.
- **If Plainsay cannot confirm the paste landed, it says so rather than
  assuming.** The dictation is kept in History marked unverified, and the menu
  offers it back until you copy or dismiss it. This is the case that matters:
  an app that swallows ⌘V silently would otherwise lose the text with no trace.

Accessibility permission is what allows the ⌘V to be delivered at all. Without
it, insertion cannot work in any app, and that is a permission problem rather
than an app-compatibility one.

## Observed behaviour

Everything below comes from **real dictations on one machine** — MacBook Air
(M4), macOS 26.6.2, Plainsay 0.2.34 — read out of Plainsay's own history and
unified log, not from a scripted test. Sample: 100 dictations between
2026-09-05 and 2026-09-19, of which 89 were inserted, 10 were discarded as too
short (a stray key tap, not a failure), and 1 could not be verified.

| App | Version | Field | Dictations | Result |
|---|---|---|---|---|
| Terminal | 2.15 | shell prompt (Claude Code session) | 69 inserted | Inserted correctly every time. No clipboard fallback, no unverified insertions. |
| ChatGPT desktop (bundle `com.openai.codex`) | 26.908.40834 | message composer | 19 inserted | Inserted correctly every time. An Electron-style composer, which is the case synthetic keystrokes usually break. |
| Notes | 4.13 | note body | 1 inserted | Inserted correctly. One dictation only — this row is the weakest in the table and should not be read as coverage of Notes. |
| Plainsay itself | 0.2.34 | Settings text field | 1 unverified | The paste could not be confirmed, so it was kept in History and offered back. Recovered by hand. Worth reproducing deliberately: it is the one observed case of the unverified path firing. |

**The clipboard fallback did not fire once in 100 dictations.** That is not
evidence it works — it is evidence it was not exercised. It needs a deliberate
test: start a dictation, click somewhere with no text field focused, and check
that the HUD says the text was saved to the clipboard and that ⌘V produces it.

## Cancelling

Escape during a recording should leave the target document untouched, because
nothing is written until a recording completes. This is **not yet covered by an
observed test** in any app, and belongs in every report below.

## Adding a row

One app, one blank test document, no code change needed. Please include:

- Plainsay version, macOS version, Mac chip.
- App name and **version**, and whether it is a native app, an Electron app, or
  a page in a browser (say which browser and version).
- Which field — a search box, a rich-text body, and a code editor are three
  different tests, and passing one says nothing about the others.
- Whether ordinary dictation inserted correctly, or needed a manual ⌘V.
- Whether cancelling with Escape left the document unchanged.
- For anything unexpected: steps to reproduce, with **non-sensitive** sample
  text. Never paste real dictation content into an issue.

An app is only marked as working for the fields actually tested. One successful
field is not proof the rest work, and a row that claims more than it observed
is worse than no row. Bugs get their own reproducible issue, linked from here.
