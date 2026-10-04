# Backlog

- **Transcript**: done on 2026-10-04 with Parakeet v3 through FluidAudio (see
  docs/superpowers/plans/2026-10-04-dabber-parakeet-subtitles.md). Open ideas:
  - split «Собеседники» by voice with FluidAudio diarization;
  - a short invented line can survive the 0.6 confidence filter (one 0.24 s "I've got" in a 24-minute silent mic
    track); measure confidences of real short replies before adding a rule;
  - the backup mic overlaps the main mic for ~2.5 s after a handoff, so a few words may appear twice;
  - quitting right after a long recording waits for its transcription (~15 s per hour per track, not
    cancellable); add a skip-on-quit if it becomes annoying;
  - no way to re-transcribe a recording delivered without a transcript (e.g. before the model was ready); a
    `--transcribe-session <folder>` command would fix it;
  - the model stays loaded while the app runs; measure idle memory (`footprint`) and load it lazily if it is large;
  - a long stereo track uses about 0.46 GB per hour in the temp folder while it is transcribed: our mono Float32
    copy plus FluidAudio's raw copy of it; writing ours as Int16 would halve our part.
- **Deferred review items** (2026-09-23): drift resampler quality (windowed-sinc instead of linear), DC high-pass
  on mics, stereo-mic channel choice, silence-rule thresholds (300 ms RMS, -70 dB), >2-channel and multi-stream
  input devices, IOProc/tap cleanup on rare start errors.
