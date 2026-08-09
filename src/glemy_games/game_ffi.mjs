// FFI implementation shared by every glemy game runner (glemy/game_tiers.gleam,
// glemy/game_breakout.gleam, ...).
//
// Thin real-browser glue: schedules requestAnimationFrame callbacks and the
// one piece of canvas-layout math every runner needs for input conversion.
// Getting the actual <canvas> element to render onto is render_ffi.mjs's
// job (glemy/render.get_canvas), not this file's -- the Canvas type it
// returns is owned by glemy/render, so its one real constructor lives
// there too. Game-specific DOM writes (score text, sound, per-game
// overlays) live in each game's own <game>_ffi.mjs, not here -- see
// glemy/game_tiers_ffi.mjs for the current example. Neither
// requestAnimationFrame nor a real DOM element exists in Deno, so unlike
// every other FFI file in this project, this one has no automated test
// coverage of its own -- but there's very little logic left in it to need
// testing (all the actual per-frame logic lives in each runner's own
// tick_and_render, which IS tested, using a real OffscreenCanvas under
// Deno; see docs/decisions.jsonl, decision 0015).

// A real, previously-observed bug: an uncaught exception anywhere in a
// frame's work (most commonly a version-skewed browser cache serving a
// stale .mjs file whose exports no longer match what a fresh index.html
// calls -- see docs/decisions.jsonl, decision 0026) silently breaks the
// requestAnimationFrame loop with zero visible symptom beyond "black
// screen": nothing further ever gets scheduled, and the actual error
// only ever reached the DevTools console, which a player has no reason
// to have open. Reporting it here, directly onto the page, turns a
// silent, undiagnosable failure into an immediately visible, actionable
// one -- this project's usual "push logic into Gleam" preference
// (decision 0016) doesn't apply to catching an *exception* specifically:
// Gleam has no try/catch-equivalent construct to express "run this and
// recover from any JS-level throw," so this has to live here, in JS.
function reportGameLoopError(error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error("glemy: uncaught error in game loop, stopped.", error);
  const errorElement = document.getElementById("glemy-error");
  if (errorElement !== null) {
    errorElement.textContent =
      "Something went wrong and the game stopped: " +
      message +
      ". Try a hard refresh (Ctrl+Shift+R / Cmd+Shift+R).";
    errorElement.hidden = false;
  }
}

// Covers a *synchronous* throw during a frame's work (see
// reportGameLoopError above).
export function requestFrame(callback) {
  globalThis.requestAnimationFrame((timestamp) => {
    try {
      callback(timestamp);
    } catch (error) {
      reportGameLoopError(error);
    }
  });
}

// Covers the *asynchronous* case the try/catch in requestFrame can't:
// each frame's actual work is a fire-and-forget promise chain (started
// inside the Gleam-compiled callback, which itself returns immediately),
// so a rejection surfacing after that -- e.g. from render_ffi.mjs's
// WebGPU calls, or from a game-specific DOM write if its elements are
// missing/mismatched -- would otherwise be a silent, invisible
// "unhandledrejection" with the exact same black-screen symptom as the
// synchronous case.
// globalThis, not window: this module also loads under Deno (gleam test
// --target javascript), where window doesn't exist (Deno 2) but
// globalThis.addEventListener does, same as a real browser (window IS
// globalThis there anyway).
globalThis.addEventListener("unhandledrejection", (event) => {
  reportGameLoopError(event.reason);
  event.preventDefault();
});

// A click's MouseEvent.clientX/clientY (glemy/io's mouse_position) are
// viewport-relative, but glemy/physics/bounds.x_from_canvas_pixel needs a
// pixel coordinate relative to the canvas's own left edge, in the same
// CSS-pixel space -- exactly what getBoundingClientRect() gives.
// getBoundingClientRect() doesn't exist on OffscreenCanvas, so unlike
// render_ffi.mjs's canvas drawing this is genuinely untestable under
// Deno (same category as requestFrame/getCanvasElement above); kept out
// of io_ffi.mjs specifically so that module's full gleam test coverage
// stays intact (see docs/decisions.jsonl, decision 0016).
export function canvasBoundingRectLeftAndWidth(canvas) {
  const rect = canvas.getBoundingClientRect();
  return [rect.left, rect.width];
}

// Sets `elementId`'s own text and visibility -- extracted once
// game_tiers_ffi.mjs's setGameOver and game_breakout_ffi.mjs's/
// game_platformer_ffi.mjs's setStatusMessage were found to be
// byte-identical, differing only in which hardcoded element id each
// one targeted (decision 0063). Each game keeps its own
// set_game_over/set_status_message Gleam-side function name and every
// existing call site, now as a thin wrapper passing its own element id
// through to this shared implementation, rather than each game's own
// FFI file repeating this DOM write from scratch.
export function setElementVisibilityMessage(elementId, visible, message) {
  const element = document.getElementById(elementId);
  element.textContent = message;
  element.hidden = !visible;
}
