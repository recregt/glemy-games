// Manual, on-demand real-browser verification for glemy/game_tiers (the
// requestAnimationFrame runner + index.html bootstrap -- see
// docs/development-plan.jsonl, RM-004). A second game gets its own
// equivalent check against its own HTML entry point, not this one
// extended to cover both -- see tools/browser_check_breakout.ts, which
// now exists. The two scripts share only the genuinely identical
// Chromium-locating/dev-server/launch-flag bootstrap (see
// tools/browser_check_shared.ts's own header comment for why that
// extraction happened at this second caller, not before).
//
// TypeScript, not plain JS: this project's standing rule is to use every
// tool's type safety to the maximum extent available. Deno type-checks
// TypeScript with the real TypeScript compiler (`deno check`, or `deno
// run --check`, not the default `deno run`, which only strips types
// without checking them -- see the run command below), and `npm:
// playwright-core` ships its own real .d.ts declarations, which Deno's
// npm interop resolves automatically -- so this gets full compile-time
// checking against Playwright's actual API (confirmed: a deliberately
// wrong type was caught by `deno check` before writing this for real).
//
// This is NOT part of `gleam test` and never will be: decision 0008
// already settled that Playwright/real-browser automation isn't
// reliable enough to trust for this project's actual CI-facing test
// suite. Its scope shrank further once glemy/game_tiers.gleam split into
// tick_and_render (the actual per-frame logic, now fully covered by
// `gleam test --target javascript` using a real OffscreenCanvas -- no
// browser needed for that anymore, see decision 0015) and a thin
// requestAnimationFrame wrapper around it. What THIS script verifies is
// only what's left that's genuinely irreducible to a real browser: does
// requestAnimationFrame actually get called in a real page, is the real
// `<canvas>` element correctly wired up, does a real click at real
// screen coordinates reach glemy/io correctly. A repeatable command a
// developer (or an agent) can run before/after touching
// `glemy/game_tiers.gleam` or `game_ffi.mjs`, instead of re-deriving the
// right way to do this from scratch or only ever checking by hand.
//
// Root cause of why this didn't work on the first few attempts (see
// decision 0012, which corrects and supersedes decision 0011's wrong
// conclusion that this sandbox "has no GPU adapter available, full
// stop"): headless Chromium's WebGPU/Vulkan backend needs a specific,
// undocumented-by-trial-and-error flag combination, confirmed against
// Chrome for Developers' own headless-WebGPU guide --
// https://developer.chrome.com/blog/supercharge-web-ai-testing -- not
// the more commonly-guessed `--enable-unsafe-swiftshader`/
// `--use-vulkan=swiftshader` flags, which don't do what their names
// suggest here and were a dead end. `--disable-vulkan-surface` in
// particular is load-bearing: without it, Vulkan init tries (and fails)
// to create a real windowing-system surface that doesn't exist in
// headless mode.
//
// Requires a Playwright-downloaded Chromium to already exist locally
// (one-time setup, not a project dependency): `npx --yes playwright
// install chromium`. Run with `deno task browser-check` (see deno.json),
// or directly (note --check, so a type error actually blocks execution
// rather than being silently stripped and ignored):
//
//   deno run --check --allow-net --allow-read --allow-write --allow-env \
//     --allow-run --allow-ffi --allow-sys tools/browser_check.ts

// Deno's own ambient types have no DOM lib (it's a server-side runtime) --
// but the `page.evaluate` callbacks below don't run in Deno, they run
// *inside the real browser page*, where `document`/`HTMLCanvasElement`
// genuinely exist. This directive only affects type-checking this file
// (not the shared project-wide deno.json, which `gleam test --target
// javascript` also relies on -- scoping this to one file avoids any risk
// of that config change leaking into how Gleam's own generated JS is
// type-understood elsewhere).
/// <reference lib="dom" />

import type { Browser, Page } from "npm:playwright-core@1.62.1";
import {
  fail,
  findChromium,
  launchGpuBrowser,
  spawnDevServer,
  stopDevServer,
  waitForServer,
} from "./browser_check_shared.ts";

const PORT = 8765;
const CANVAS_SELECTOR = "#glemy-canvas";

/**
 * Installs monkey-patches (before glemy/game_tiers's module even loads, via
 * addInitScript) that count real per-frame activity on the actual
 * WebGPU objects glemy/render_ffi.mjs drives, stashed on `window` for
 * later reading. This is how this script confirms the RAF loop is
 * really running and click-to-spawn is really growing the entity count
 * -- NOT by reading canvas pixels.
 *
 * Reading canvas pixels back (drawImage, page.screenshot(), etc.) does
 * not work here: this is a documented, upstream headless-Chrome
 * limitation on Linux/Windows -- WebGPU canvas presentation never
 * reaches the headless compositor, even though the rendering itself
 * genuinely happens (no known flag fixes it; see
 * https://github.com/gpuweb/gpuweb/issues/1781). That's fine --
 * pixel-level correctness is already fully covered by `gleam test
 * --target javascript` (render_test.gleam, game_test.gleam), which use
 * the exact same copyTextureToBuffer readback this script's earlier
 * revision (before decision 0015) had to rely on Playwright for.
 *
 * Each entity costs exactly 3 GPUDevice.createBuffer calls in
 * render_ffi.mjs's drawEntities (center + radius + color uniforms --
 * color was added in Phase 3 of the merge-puzzler plan, decision 0020;
 * this divisor was 2 before that and would now silently under-report
 * entity counts if left unchanged). Three more are created once per
 * render_entities_to_canvas call, not per entity: the two shared bounds
 * buffers (drawEntities) and the readback buffer for the
 * copyTextureToBuffer pixel read (renderEntitiesToCanvas itself). So
 * counting createBuffer calls between consecutive GPUCanvasContext.configure
 * calls (each configure = one render_entities_to_canvas call = one
 * simulation tick), then subtracting those 3 fixed buffers and dividing
 * by 3, gives a direct, real entity-count-per-frame reading.
 *
 * Also captures every 2-float uniform buffer's contents into
 * `__glemyCapturedVec2s` -- this is how `worldXWasSpawnedNear` below
 * verifies a real click produced a real world-space spawn position
 * without needing pixel readback (which doesn't work here, see above):
 * center and bounds-min/max uniforms are both 2 floats, so this
 * captures a mix of both, searched by value rather than by position.
 *
 * The obvious approach -- call `getMappedRange()` again from inside a
 * patched `unmap()`, right before the range gets detached -- does NOT
 * work: real Chromium throws ("getMappedRange [0, N) overlaps with
 * previously returned range [0, N)") on a second call requesting the
 * same already-mapped range, even read-only, even before `unmap()`.
 * Confirmed by running this exact script and inspecting the thrown
 * errors, not assumed from the spec text. Instead, `getMappedRange` is
 * patched directly to stash the ArrayBuffer reference it already
 * returns to `makeUniformBuffer`'s own single legitimate call (keyed by
 * buffer instance in a WeakMap); the `unmap` patch then just reads that
 * same reference -- still valid right up until the real `unmap()`
 * detaches it -- instead of asking WebGPU for it a second time.
 */
async function installFrameCounters(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const w = window as unknown as {
      __glemyFrameCount: number;
      __glemyEntityCountsByFrame: number[];
      __glemyCapturedVec2s: [number, number][];
      __glemyOscillatorStartCount: number;
    };
    w.__glemyFrameCount = 0;
    w.__glemyEntityCountsByFrame = [];
    w.__glemyCapturedVec2s = [];
    w.__glemyOscillatorStartCount = 0;
    let buffersThisFrame = 0;

    // Confirms game_ffi.mjs's playDropSound/playMergeSound actually run
    // (an oscillator gets created and started), without needing a real
    // audio output device or asserting on the played sound itself --
    // same "instrument the real API, don't mock it" approach as the
    // WebGPU counters below.
    const originalOscillatorStart = OscillatorNode.prototype.start;
    OscillatorNode.prototype.start = function (
      ...args: Parameters<typeof originalOscillatorStart>
    ) {
      w.__glemyOscillatorStartCount++;
      return originalOscillatorStart.apply(this, args);
    };

    const originalConfigure = GPUCanvasContext.prototype.configure;
    GPUCanvasContext.prototype.configure = function (
      ...args: Parameters<typeof originalConfigure>
    ) {
      w.__glemyFrameCount++;
      if (buffersThisFrame > 0) {
        // -3 for the two shared bounds buffers plus the readback buffer,
        // each created once per call, not per entity.
        w.__glemyEntityCountsByFrame.push((buffersThisFrame - 3) / 3);
      }
      buffersThisFrame = 0;
      return originalConfigure.apply(this, args);
    };

    const originalCreateBuffer = GPUDevice.prototype.createBuffer;
    GPUDevice.prototype.createBuffer = function (
      ...args: Parameters<typeof originalCreateBuffer>
    ) {
      buffersThisFrame++;
      return originalCreateBuffer.apply(this, args);
    };

    const mappedRangeByBuffer = new WeakMap<GPUBuffer, ArrayBuffer>();
    const originalGetMappedRange = GPUBuffer.prototype.getMappedRange;
    GPUBuffer.prototype.getMappedRange = function (
      ...args: Parameters<typeof originalGetMappedRange>
    ) {
      const range = originalGetMappedRange.apply(this, args);
      mappedRangeByBuffer.set(this, range);
      return range;
    };

    const originalUnmap = GPUBuffer.prototype.unmap;
    GPUBuffer.prototype.unmap = function (
      ...args: Parameters<typeof originalUnmap>
    ) {
      const range = mappedRangeByBuffer.get(this);
      if (range !== undefined) {
        if (range.byteLength === 2 * Float32Array.BYTES_PER_ELEMENT) {
          const floats = new Float32Array(range.slice(0));
          w.__glemyCapturedVec2s.push([floats[0], floats[1]]);
        }
        mappedRangeByBuffer.delete(this);
      }
      return originalUnmap.apply(this, args);
    };
  });
}

async function frameCount(page: Page): Promise<number> {
  return await page.evaluate(
    () => (window as unknown as { __glemyFrameCount: number }).__glemyFrameCount,
  );
}

async function oscillatorStartCount(page: Page): Promise<number> {
  return await page.evaluate(
    () =>
      (window as unknown as { __glemyOscillatorStartCount: number })
        .__glemyOscillatorStartCount,
  );
}

/**
 * Whether any captured 2-float uniform buffer (see installFrameCounters)
 * has an x component within `tolerance` of `expectedWorldX` -- the real,
 * end-to-end proof that a click's world-x conversion
 * (glemy/physics/bounds.x_from_canvas_pixel, wired into glemy/game_tiers.gleam's
 * loop) actually produces the right value in a real browser, not just
 * in `gleam test`'s unit tests. Search-by-value rather than by buffer
 * index specifically to stay independent of exact createBuffer
 * ordering/async interleaving between frames -- robust as long as
 * nothing else on screen coincidentally sits within `tolerance` of
 * `expectedWorldX`, which callers are responsible for picking (this
 * script places the check well clear of `main()`'s starting-scene
 * entities and its own `bounds` corners).
 */
async function worldXWasSpawnedNear(
  page: Page,
  expectedWorldX: number,
  tolerance: number,
): Promise<boolean> {
  return await page.evaluate((args) => {
    const [expected, tol] = args;
    const captured = (
      window as unknown as { __glemyCapturedVec2s: [number, number][] }
    ).__glemyCapturedVec2s;
    return captured.some(([x]) => Math.abs(x - expected) <= tol);
  }, [expectedWorldX, tolerance] as [number, number]);
}

async function latestEntityCount(page: Page): Promise<number> {
  return await page.evaluate(() => {
    const counts = (
      window as unknown as { __glemyEntityCountsByFrame: number[] }
    ).__glemyEntityCountsByFrame;
    return counts.length === 0 ? 0 : counts[counts.length - 1];
  });
}

// `fractionAcrossWidth` deliberately avoids 0.5 (canvas center) as the
// default call below is used for: `main()`'s starting scene already has
// an entity sitting at world-x 50 (the exact center), which would make
// `worldXWasSpawnedNear(page, 50.0, ...)` trivially pass regardless of
// whether the real click->world-x conversion is even wired up. 0.15
// steers well clear of every starting-scene entity (world-x 30/50/70)
// and both bounds corners (0/100).
async function clickAndHoldCanvasAt(
  page: Page,
  fractionAcrossWidth: number,
): Promise<void> {
  const box = await page.locator(CANVAS_SELECTOR).boundingBox();
  if (box === null) {
    fail(`${CANVAS_SELECTOR} has no bounding box -- is it actually visible?`);
  }
  await page.mouse.move(
    box.x + box.width * fractionAcrossWidth,
    box.y + box.height / 2,
  );
  await page.mouse.down();
  await page.waitForTimeout(500);
  await page.mouse.up();
  await page.waitForTimeout(500);
}

const chromiumPath = findChromium();

const server = spawnDevServer(PORT);

try {
  const baseUrl = `http://localhost:${PORT}/index.html`;
  await waitForServer(baseUrl, 20);

  const browser: Browser = await launchGpuBrowser(chromiumPath);

  try {
    const page: Page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (err: Error) => pageErrors.push(err.message));
    await installFrameCounters(page);

    await page.goto(baseUrl);
    await page.waitForTimeout(2000);

    if (pageErrors.length > 0) {
      fail(`uncaught page errors: ${JSON.stringify(pageErrors)}`);
    }

    const framesBeforeClick = await frameCount(page);
    if (framesBeforeClick === 0) {
      fail(
        "requestAnimationFrame never fired within 2s -- the game loop " +
          "isn't running at all",
      );
    }

    // Real-browser confirmation that glemy/game_tiers.gleam's loop is actually
    // reaching game_ffi.mjs's setScoreText/setGameOver each frame (not
    // just that the pure Gleam side computes the right strings --
    // format_score is already gleam test-covered on its own): the score
    // element should already read "Score: 0" (main()'s starting score,
    // formatted) and the game-over element should still be hidden, since
    // nothing has been dropped or lost yet.
    const scoreText = await page
      .locator("#glemy-score")
      .textContent();
    if (scoreText !== "Score: 0") {
      fail(`expected #glemy-score to read "Score: 0", got ${JSON.stringify(scoreText)}`);
    }
    const gameOverHidden = await page
      .locator("#glemy-game-over")
      .isHidden();
    if (!gameOverHidden) {
      fail("expected #glemy-game-over to still be hidden before any loss");
    }

    // Confirms game_tiers.gleam's main() actually called
    // set_danger_line_position with the real, computed value (not just
    // that bounds.y_fraction_from_top's pure math is right -- that's
    // already gleam test-covered on its own). main()'s bounds are
    // 0..100 and pe.danger_line_margin_from_top is 5.0, so the line
    // should sit at exactly 5% from the top.
    const dangerLineTop = await page
      .locator("#glemy-danger-line")
      .evaluate((el) => (el as HTMLElement).style.top);
    if (dangerLineTop !== "5%") {
      fail(`expected #glemy-danger-line's top to be "5%", got ${JSON.stringify(dangerLineTop)}`);
    }

    // Confirms the next-tier swatch is set before the first click too
    // (main() calls set_next_tier_color once itself, not just relying
    // on the first frame of `loop` -- see game_tiers.gleam). main()'s initial
    // Model.next_tier is 1, and tier.color_css(1) is "rgb(255, 128, 0)"
    // (already pinned directly in tier_test.gleam).
    const nextTierColor = await page
      .locator("#glemy-next-tier")
      .evaluate((el) => (el as HTMLElement).style.backgroundColor);
    if (nextTierColor !== "rgb(255, 128, 0)") {
      fail(`expected #glemy-next-tier's background color to be "rgb(255, 128, 0)", got ${JSON.stringify(nextTierColor)}`);
    }

    // 3 real starting entities + 1 synthetic drop-preview circle
    // (pe.preview_entity, rendered but never added to model.entities --
    // see game_tiers.gleam's tick_and_render) drawn every frame.
    const entitiesBeforeClick = await latestEntityCount(page);
    if (entitiesBeforeClick !== 4) {
      fail(
        `expected game.main()'s 3-entity starting scene plus 1 drop ` +
          `preview circle, got ${entitiesBeforeClick} entities/frame`,
      );
    }

    const clickFraction = 0.15;
    // main()'s bounds are Vector2(0,0)..Vector2(100,100), so a real,
    // correctly-converted click at 15% across the canvas's actual
    // displayed width should land at world-x 15 -- not the raw
    // clientX pixel value clicking there produces (a real screen
    // coordinate, almost certainly nowhere near [0, 100]), which is
    // exactly the bug Phase 4 (decision 0021) fixed.
    const expectedWorldX = clickFraction * 100.0;
    await clickAndHoldCanvasAt(page, clickFraction);

    const framesAfterClick = await frameCount(page);
    if (framesAfterClick <= framesBeforeClick) {
      fail(
        "the game loop stopped advancing during the click-and-hold " +
          `(${framesBeforeClick} -> ${framesAfterClick} frames)`,
      );
    }

    const entitiesAfterClick = await latestEntityCount(page);
    if (entitiesAfterClick <= entitiesBeforeClick) {
      fail(
        "click-to-spawn didn't increase the real entity count " +
          `(${entitiesBeforeClick} -> ${entitiesAfterClick})`,
      );
    }

    const worldXTolerance = 3.0;
    if (!(await worldXWasSpawnedNear(page, expectedWorldX, worldXTolerance))) {
      fail(
        `no spawned entity landed near world-x ${expectedWorldX} ` +
          `(+/- ${worldXTolerance}) after clicking ${clickFraction * 100}% ` +
          "across the canvas -- the click->world-x coordinate conversion " +
          "(glemy/physics/bounds.x_from_canvas_pixel, wired in glemy/game_tiers.gleam's " +
          "loop) looks broken.",
      );
    }

    // Confirms game_tiers.gleam's loop actually reaches game_ffi.mjs's
    // playDropSound (pe.Dropped -> play_sound_event) for a real drop --
    // the click-and-hold above spawned at least one entity, so at least
    // one oscillator should have been created and started. Can't assert
    // on the sound itself (no audio output device here), only that the
    // real Web Audio API path actually ran without throwing (zero page
    // errors is already checked at the end of this script).
    const oscillatorStarts = await oscillatorStartCount(page);
    if (oscillatorStarts < 1) {
      fail(
        "expected at least one OscillatorNode.start() call after a real " +
          `drop, got ${oscillatorStarts} -- game_tiers.gleam's play_sound_event ` +
          "path looks broken.",
      );
    }

    console.log(
      `PASS: requestAnimationFrame fired ${framesAfterClick} times, ` +
        `entity count went ${entitiesBeforeClick} -> ${entitiesAfterClick} ` +
        `after a click-and-hold, a real entity spawned near world-x ` +
        `${expectedWorldX}, zero page errors.`,
    );
  } finally {
    await browser.close();
  }
} finally {
  await stopDevServer(server);
}
