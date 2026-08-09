// Test-only helper for game_breakout_test.gleam: creates a real
// OffscreenCanvas for glemy/game_breakout.tick_and_render to render onto
// -- same rationale as test/glemy/render_test_ffi.mjs (kept as its own
// small file per-test-file, matching this project's existing convention,
// e.g. io_test_ffi.mjs).

export function createOffscreenCanvas(width, height) {
  return new OffscreenCanvas(width, height);
}

// A canvas can only ever be bound to one context type for its whole
// lifetime. Claiming "bitmaprenderer" first is a real, working way to
// put a canvas in the state render_entities_to_canvas has to handle: a
// subsequent getContext("webgpu") call genuinely returns null.
export function createCanvasWithNoWebgpuContext(width, height) {
  const canvas = new OffscreenCanvas(width, height);
  canvas.getContext("bitmaprenderer");
  return canvas;
}
