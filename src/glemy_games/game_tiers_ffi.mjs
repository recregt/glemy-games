// FFI implementation of glemy/game_tiers -- the Tiers-specific DOM writes
// and sound effects for index.html's #glemy-score/#glemy-game-over/
// #glemy-danger-line/#glemy-next-tier/#glemy-canvas-wrap elements. Split
// out from game_ffi.mjs (decision 0051) so that file stays generic runner
// infrastructure shared by every game, and each game's own overlay/sound
// concerns stay local to that game's own FFI file -- glemy/game_breakout_ffi.mjs
// is the sibling example.

// Non-branching DOM writes only -- the text itself is already fully
// computed on the Gleam side (glemy/game_tiers.gleam's format_score, the
// game_over Bool straight off Model) before it ever reaches here; see
// docs/decisions.jsonl, decision 0016.
export function setScoreText(text) {
  document.getElementById("glemy-score").textContent = text;
}

// Called once at startup (the danger line's world-y never changes), not
// every frame like setScoreText above (setGameOver moved to
// game_ffi.mjs's shared setElementVisibilityMessage, decision 0063) --
// percentFromTop is already fully computed on the Gleam side
// (bounds.y_fraction_from_top), this is just the write.
export function setDangerLinePosition(percentFromTop) {
  document.getElementById("glemy-danger-line").style.top =
    `${percentFromTop * 100}%`;
}

// css is already a fully-formed "rgb(...)" string (glemy/games/tiers/rules's
// color_css) -- same non-branching-DOM-write reasoning as setScoreText.
export function setNextTierColor(css) {
  document.getElementById("glemy-next-tier").style.backgroundColor = css;
}

// Synthesized, not loaded from audio files: this project has no asset
// pipeline and no third-party dependencies (decisions 0013/0015), and a
// short percussive blip is well within what a couple of Web Audio nodes
// can produce directly -- genuinely simpler than adding an assets/
// directory and file-loading machinery for two tiny sound effects.
//
// One shared, lazily-created AudioContext (same singleton reasoning as
// gpu_ffi.mjs's shared GPUDevice: browsers cap how many contexts can
// exist, and there's no reason for more than one here). Created lazily,
// not at module load, since most browsers require a real user gesture
// (a click) before audio can play at all -- by the time any sound
// actually needs to play, a drop has already happened, which is itself
// a click, so this never actually hits that restriction in practice.
let audioContext;
function getAudioContext() {
  if (audioContext === undefined) {
    audioContext = new AudioContext();
  }
  return audioContext;
}

// A single short, percussive tone: an oscillator through a gain node
// whose envelope is scheduled (setValueAtTime + exponentialRampToValueAtTime),
// not just assigned a value directly -- assigning .gain.value directly
// for an on/off tone produces an audible click/pop artifact of its own
// (a discontinuity in the waveform), which scheduling a smooth ramp
// avoids. exponential, not linear: matches how human hearing perceives
// loudness (roughly logarithmic), so it sounds like a more natural decay.
function playTone(frequency, durationSeconds) {
  const ctx = getAudioContext();
  const oscillator = ctx.createOscillator();
  const gain = ctx.createGain();
  oscillator.frequency.value = frequency;
  oscillator.connect(gain);
  gain.connect(ctx.destination);

  const now = ctx.currentTime;
  gain.gain.setValueAtTime(0.2, now);
  // exponentialRampToValueAtTime can't target exactly 0 (it's a
  // multiplicative curve), so this ramps to a small-but-nonzero floor
  // instead -- inaudible in practice, and avoids a thrown RangeError.
  gain.gain.exponentialRampToValueAtTime(0.0001, now + durationSeconds);

  oscillator.start(now);
  oscillator.stop(now + durationSeconds);
}

// A low, short blip for a piece landing -- tiers.Dropped.
export function playDropSound() {
  playTone(220, 0.08);
}

// A higher, slightly longer blip for a successful merge -- tiers.Merged.
// Higher-pitched than the drop sound so the two are distinguishable by
// ear alone, matching genre convention (a "success" sound reads higher
// than a neutral "thud").
export function playMergeSound() {
  playTone(660, 0.12);
}

// Briefly flashes #glemy-canvas-wrap (see index.html's glemy-merge-flash
// keyframes) for tiers.Merged. Removing the class before re-adding it (and
// forcing a reflow via reading offsetWidth in between) is necessary, not
// decorative -- re-adding a class that's already present doesn't restart
// a CSS animation on its own, which would make back-to-back merges
// within 0.2s only flash once instead of once each.
export function triggerMergeFlash() {
  const el = document.getElementById("glemy-canvas-wrap");
  el.classList.remove("glemy-flash");
  void el.offsetWidth;
  el.classList.add("glemy-flash");
}
