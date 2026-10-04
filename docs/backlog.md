# Backlog

- **Transcript**: done on 2026-10-04 with Parakeet v3 through FluidAudio (see
  docs/superpowers/plans/2026-10-04-dabber-parakeet-subtitles.md). Open ideas:
  - split «Собеседники» by voice with FluidAudio diarization;
  - drop mic text that is the other side heard through the speakers (no headphones);
  - a short invented line can survive the 0.7 confidence filter (one 0.24 s "I've got" in a 24-minute silent mic
    track); measure confidences of real short replies before adding a rule;
  - the backup mic overlaps the main mic for ~2.5 s after a handoff, so a few words may appear twice;
  - quitting right after a long recording waits for its transcription (~15 s per hour per track, not
    cancellable); add a skip-on-quit if it becomes annoying;
  - no way to re-transcribe a recording delivered without a transcript (e.g. before the model was ready); a
    `--transcribe-session <folder>` command would fix it;
  - the first launch downloads ~470 MB silently, with no progress in the menu;
  - the model stays loaded while the app runs; measure idle memory (`footprint`) and load it lazily if it is large.
- **Deferred review items** (2026-09-23): drift resampler quality (windowed-sinc instead of linear), DC high-pass
  on mics, stereo-mic channel choice, silence-rule thresholds (300 ms RMS, -70 dB), >2-channel and multi-stream
  input devices, IOProc/tap cleanup on rare start errors.
