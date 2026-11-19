# Dictation evaluation data

Google FLEURS, by Google and the FLEURS contributors, is licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Use the original WAV and raw transcription columns from [google/fleurs at revision 70bb2e8](https://huggingface.co/datasets/google/fleurs/tree/70bb2e84b976b7e960aa89f1c648e09c59f894dd).

DEV is 60 clips each from Polish (`pl_pl`) and US English (`en_us`) in FLEURS `dev`. HELD-OUT is 40 each from FLEURS `test`. Within each language and split, rank clips by SHA-256 of `plainsay-fleurs-v1/<locale>/<split>/<filename>` and select a 50/50 balance of the two source gender labels. Select in DEV-before-HELD-OUT and Polish-before-English order, using each source sentence ID at most once across both languages and splits. The manifests alternate languages. This is short read speech and gives no estimate for spontaneous dictation, code switching within a clip, noisy microphones, or long dictation.

The manifests pin the locale, FLEURS sentence ID, source WAV filename stem, WAV SHA-256 and raw reference SHA-256. WAVs, transcripts, archives, models and run logs go in the workspace's sibling `../data` directory outside Git. On a fresh checkout run:

```sh
eval/prepare_data dataset
eval/prepare_data models all
eval/run_eval dev > ../data/dev.json
eval/run_eval heldout > ../data/heldout.json
```

The public Core ML snapshots are pinned by Plainsay in `ModelDigests.swift`. The Whisper tokenizer uses [OpenAI Whisper Large v3 revision 06f233f](https://huggingface.co/openai/whisper-large-v3/tree/06f233fe06e710322aca913c1bc4249a0d71fce1). The eval uses local model files, isolated preferences, the seeded vocabulary, Polish as primary and English as the other spoken language, default empty replacement rules, and Polishing off.

Score both sides identically. Apply canonical Unicode composition, lowercase, preserve Polish diacritics, remove an apostrophe between letters, and treat other nonletter/nondigit characters as word separators. Spell out standalone integers from 0 to 999,999,999 using Foundation's locale spell-out formatter for the clip's language and tokenize the resulting words. Leading-zero strings and mixed letter/digit tokens keep their literal form. Punctuation inside decimals, grouped numbers and dates splits the expressions into tokens. Inflected numbers and alternative year readings can still differ.

WER per language is total word-level Levenshtein edits divided by total normalized reference words. The scalar score is the arithmetic mean of the two WERs, expressed as a fraction. Empty hypotheses count as deletions. Bad hashes, unreadable audio and engine errors fail the run. DEV JSON contains per-clip diagnostics. HELD-OUT JSON contains aggregate metrics.

Latency starts with the complete PCM already in memory and ends with final sanitized text. This models audio-end-to-text for an idle app with a prepared engine. It excludes live capture and release handling, speaker filtering, model preparation, file I/O, scoring, UI and pasteboard operations. Mean and nearest-rank p90 cover both languages. The loop rejects DEV if p90 exceeds 115% of baseline DEV p90. Each eval uses one resident engine and processes clips serially, with no unmeasured utterance warm-up.

From a clean baseline commit on `autoresearch/dictation-quality`, `eval/run_loop` writes `results.tsv` and saves JSON and stderr to `../data/logs/loop`. The hypotheses are in `eval/hypotheses.tsv`. It tries Parakeet first, then follows the hypotheses for the retained engine, checks the root volume before each run, and enforces the 8-minute DEV, 30-trial and 4-hour loop limits.
