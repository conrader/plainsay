# Ten-person pre-launch test

The purpose is to find friction and misleading copy, not to generate stars,
votes, testimonials, or public posts. Ask testers not to promote the project
until the dry run is closed.

## Recruit a useful mix

Choose ten people across these dimensions rather than ten similar coworkers:

- Apple-silicon generations, including the oldest available supported Mac and
  newer machines;
- the oldest supported macOS 14 release, later supported releases, and the
  current supported macOS;
- four Polish-first speakers, three bilingual Polish/English speakers, and
  three English-first speakers;
- people who already use dictation and people who do not;
- daily destinations including Notes, browser text fields, Slack or Discord,
  an Electron app, a code editor, and a terminal;
- at least two installs through Homebrew and the remainder through the DMG.

Do not recruit only developers. First-run permissions and trust wording matter
most when the tester has not read the repository.

## Invitation message

> Hi — I am testing Plainsay, a small Mac dictation app, before its public
> launch. Could you give it 20 minutes on an Apple-silicon Mac running macOS 14
> or newer?
>
> I would like you to install the exact test build, choose the default Local
> mode, complete one Polish and/or English dictation, and then try it in two
> apps you actually use. I am testing the onboarding, permissions, trust, and
> insertion flow — not your speaking ability.
>
> Please do not star, share, review, or post about it yet. Honest friction is
> more useful than promotion. You do not need to send audio or private text;
> use neutral sample sentences and share only details you are comfortable
> sharing.
>
> Test build: [VERSION AND LINK]<br>
> Test window: [DATE/TIME]<br>
> Feedback form or call: [LINK]

Send invitations individually. Replace every placeholder and record explicit
consent before quoting a tester publicly.

## Moderator script

1. Record Mac model, macOS version, install route, app build, and primary
   language before the install.
2. Ask the tester to think aloud. Do not explain Local, Cloud, permissions, or
   the shortcut until they have interpreted the screen themselves.
3. Start a timer when they open the DMG or run the Homebrew command. Record time
   to launch and time to the first successful inserted transcript.
4. Ask for one neutral Polish and/or English sentence in Notes.
5. Ask for two normal dictations in apps the tester already uses.
6. Ask them to find the Cloud option and explain, in their own words, what data
   would leave the Mac and what it costs. Do not correct them until their answer
   is recorded.
7. Ask what they believe “12 MB,” “local,” “free,” and “open source” each refer
   to.
8. End with intent questions, then disclose any interpretation they got wrong.

## Qualitative data checklist

For each tester, capture:

- tester ID, consent status, build, Mac, macOS, install route, and languages;
- successful install: yes/no, with the exact blocking screen or message;
- time to app launch and time to first successful inserted dictation;
- which permission prompt caused hesitation, denial, or an unnecessary loop;
- mode the tester believed was selected and why;
- selected local engine/model, model-download duration, and whether the size
  was expected;
- intended neutral sentence and actual transcript, only with consent;
- perceived delay after key release, plus any hang, dropped dictation, or
  unexpected fallback;
- each destination app and field type, insertion success, formatting damage,
  lost selection, and whether the previous clipboard content was restored;
- Polish/English language switching behavior and any manual step the tester did
  not expect;
- what the tester thinks leaves the Mac in Local, hosted Polishing, and Cloud;
- what the tester believes is free, paid, MIT-licensed, and not open source;
- the first moment that felt untrustworthy or confusing;
- the most useful moment and the feature they would remove first;
- whether they would use it again next week, and the one obstacle preventing
  that;
- permission to follow up and separate permission for any public quote.

Do not collect dictated audio by default. If a defect genuinely requires it,
ask separately, explain where the file will be stored and for how long, and
provide a deletion path.

## Severity labels

- **P0 — stop launch:** install cannot complete; crash or hang in the core flow;
  data or clipboard loss; audio sent contrary to the selected mode; misleading
  privacy, price, open-source, or size interpretation shared by more than one
  tester.
- **P1 — fix before broad launch:** repeated permission loop; first dictation
  fails; common app cannot receive text; language selection is unclear; two or
  more testers make the same wrong assumption.
- **P2 — document or schedule:** isolated layout/copy issue with a clear
  workaround; unsupported destination; preference request.

## Exit gate

Proceed to the first public feedback channel only when:

- at least eight of ten testers complete a Local dictation without help;
- all ten can eventually explain that Local keeps audio on the Mac and Cloud
  sends recorded audio;
- no P0 remains open;
- no repeated P1 remains open without a tested fix;
- the DMG and Homebrew paths install the same build;
- the published demo uses that build and shows a genuine, untouched result;
- every recurring objection has a direct answer in the README or FAQ.

Preserve the raw notes, but publish only aggregated findings unless a tester
has explicitly approved a quote and attribution.
