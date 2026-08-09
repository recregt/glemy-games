// FFI implementation of glemy/game_breakout -- the Breakout-specific DOM
// writes and sound effects for breakout.html's #glemy-score/#glemy-status/
// #glemy-paddle/#glemy-bricks elements. Sibling to game_tiers_ffi.mjs
// (decision 0051/0052): each game keeps its own overlay/sound concerns
// local to its own FFI file, sharing only the genuinely generic
// game_ffi.mjs.

// Non-branching DOM write -- the text itself is already fully computed
// on the Gleam side (glemy/game_breakout.gleam's format_score) before it
// ever reaches here; see docs/decisions.jsonl, decision 0016.
export function setScoreText(text) {
  document.getElementById("glemy-score").textContent = text;
}

// left/top/width/height are already fully computed 0.0-1.0 fractions on
// the Gleam side (glemy/game_breakout.gleam's rect_to_css) -- this is
// just the write, scaled to a CSS percentage.
export function setPaddleBox(left, top, width, height) {
  const element = document.getElementById("glemy-paddle");
  element.style.left = `${left * 100}%`;
  element.style.top = `${top * 100}%`;
  element.style.width = `${width * 100}%`;
  element.style.height = `${height * 100}%`;
}

// `bricks` is a Gleam List of #(id, left, top, width, height) tuples --
// Gleam tuples compile to plain JS arrays (same fact render_ffi.mjs's
// own drawEntities already relies on), so this destructures directly.
// Called once at startup (glemy/game_breakout.gleam's main): bricks are
// static, only ever destroyed (hideBrickElement, below), never added or
// repositioned after this.
export function createBrickElements(bricks) {
  const container = document.getElementById("glemy-bricks");
  container.innerHTML = "";
  bricks.toArray().forEach(([id, left, top, width, height]) => {
    const element = document.createElement("div");
    element.className = "glemy-brick";
    element.dataset.brickId = String(id);
    element.style.left = `${left * 100}%`;
    element.style.top = `${top * 100}%`;
    element.style.width = `${width * 100}%`;
    element.style.height = `${height * 100}%`;
    container.appendChild(element);
  });
}

// Keyed by id, not list/DOM position -- see
// glemy/games/breakout.Brick's own doc comment for why a brick's
// position in whatever list currently remains isn't a safe key across
// frames (destroying an earlier brick shifts every later one's index).
export function hideBrickElement(id) {
  const element = document.querySelector(`[data-brick-id="${id}"]`);
  if (element !== null) {
    element.hidden = true;
  }
}

// Synthesized, not loaded from audio files -- same reasoning as
// game_tiers_ffi.mjs's own playTone (this project has no asset pipeline
// or third-party dependencies, decisions 0013/0015). One shared, lazily-
// created AudioContext, same singleton reasoning as gpu_ffi.mjs's shared
// GPUDevice and game_tiers_ffi.mjs's own audioContext -- kept as this
// file's own instance rather than shared with game_tiers_ffi.mjs, since
// the two games' compiled output never loads on the same page together
// (each has its own HTML entry point).
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

// A short, low blip for a wall/paddle bounce -- breakout.BallBounced.
export function playBounceSound() {
  playTone(330, 0.06);
}

// A higher, slightly longer blip for a brick breaking --
// breakout.BrickDestroyed. Higher-pitched than the bounce sound so the
// two are distinguishable by ear alone, same genre-convention reasoning
// as game_tiers_ffi.mjs's drop/merge sound pair.
export function playBrickSound() {
  playTone(880, 0.1);
}
