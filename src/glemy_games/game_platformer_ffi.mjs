// FFI implementation of glemy/game_platformer -- the platformer-specific
// DOM writes and sound effects for platformer.html's
// #glemy-status/#glemy-platforms/#glemy-goal elements. Sibling to
// game_breakout_ffi.mjs/game_tiers_ffi.mjs (decisions 0051/0052): each
// game keeps its own overlay/sound concerns local to its own FFI file,
// sharing only the genuinely generic game_ffi.mjs.

// `platforms` is a Gleam List of #(left, top, width, height) tuples --
// Gleam tuples compile to plain JS arrays, same fact
// game_breakout_ffi.mjs's own createBrickElements already relies on.
// `goal` is a single such tuple, not a list -- there's only ever one.
// Called once at startup (glemy/game_platformer.gleam's main) and never
// again: platforms and the goal are static, unlike Breakout's own
// destructible bricks, so there's no per-element key or hide/destroy
// path to wire up here at all.
export function createLevelElements(platforms, goal) {
  const platformsContainer = document.getElementById("glemy-platforms");
  platformsContainer.innerHTML = "";
  platforms.toArray().forEach(([left, top, width, height]) => {
    const element = document.createElement("div");
    element.className = "glemy-platform";
    element.style.left = `${left * 100}%`;
    element.style.top = `${top * 100}%`;
    element.style.width = `${width * 100}%`;
    element.style.height = `${height * 100}%`;
    platformsContainer.appendChild(element);
  });

  const [left, top, width, height] = goal;
  const goalElement = document.getElementById("glemy-goal");
  goalElement.style.left = `${left * 100}%`;
  goalElement.style.top = `${top * 100}%`;
  goalElement.style.width = `${width * 100}%`;
  goalElement.style.height = `${height * 100}%`;
}

// Synthesized, not loaded from audio files -- same reasoning as
// game_breakout_ffi.mjs's own playTone. One shared, lazily-created
// AudioContext, kept as this file's own instance rather than shared
// with any other game's FFI, since the two games' compiled output never
// loads on the same page together (each has its own HTML entry point).
let audioContext;
function getAudioContext() {
  if (audioContext === undefined) {
    audioContext = new AudioContext();
  }
  return audioContext;
}

function playTone(frequency, durationSeconds) {
  const ctx = getAudioContext();
  const oscillator = ctx.createOscillator();
  const gain = ctx.createGain();
  oscillator.frequency.value = frequency;
  oscillator.connect(gain);
  gain.connect(ctx.destination);

  const now = ctx.currentTime;
  gain.gain.setValueAtTime(0.2, now);
  gain.gain.exponentialRampToValueAtTime(0.0001, now + durationSeconds);

  oscillator.start(now);
  oscillator.stop(now + durationSeconds);
}

// A short, rising blip for a jump -- platformer.Jumped.
export function playJumpSound() {
  playTone(440, 0.08);
}

// A short, lower blip for landing -- platformer.Landed. Lower-pitched
// than the jump sound so the two are distinguishable by ear alone, same
// genre-convention reasoning as game_breakout_ffi.mjs's bounce/brick
// sound pair.
export function playLandSound() {
  playTone(220, 0.06);
}
