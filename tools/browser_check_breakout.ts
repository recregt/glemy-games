// Manual, on-demand real-browser verification for glemy/game_breakout
// (breakout.html's requestAnimationFrame runner) -- the Breakout
// counterpart to tools/browser_check.ts (see that file's own header
// comment, and tools/browser_check_shared.ts's, for why this is a
// separate script sharing only the launch/dev-server bootstrap).
//
// What this checks that `gleam test --target javascript` structurally
// can't (real requestAnimationFrame, a real <canvas>, real keyboard
// events reaching glemy/io): the RAF loop actually runs; a real held
// ArrowLeft keypress actually moves the real #glemy-paddle overlay div
// (glemy/io.is_key_down's first real caller -- see
// docs/decisions.jsonl); a real ball-brick collision actually happens
// and is reflected in the real DOM (a brick div hidden, the score text
// updated) -- not just that brick.resolve_first_hit's pure logic is
// right in isolation.
//
// Requires a Playwright-downloaded Chromium to already exist locally,
// same one-time setup as tools/browser_check.ts: `npx --yes playwright
// install chromium`. Run with `deno task browser-check-breakout`.

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

const PORT = 8766;
const PADDLE_SELECTOR = "#glemy-paddle";

/**
 * Same real-API-instrumentation approach as
 * tools/browser_check.ts's own installFrameCounters -- counts real
 * GPUCanvasContext.configure calls (one per render_entities_to_canvas
 * call, i.e. one per simulation tick) to confirm the RAF loop is really
 * running, and real OscillatorNode.start() calls to confirm a sound
 * effect really played -- without relying on canvas pixel readback
 * (which is a documented, upstream headless-Chrome limitation on
 * Linux/Windows, see that file's own comment for the citation) or a
 * real audio output device.
 */
async function installCounters(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const w = window as unknown as {
      __glemyFrameCount: number;
      __glemyOscillatorStartCount: number;
    };
    w.__glemyFrameCount = 0;
    w.__glemyOscillatorStartCount = 0;

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
      return originalConfigure.apply(this, args);
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

async function hiddenBrickCount(page: Page): Promise<number> {
  return await page.locator(".glemy-brick[hidden]").count();
}

// A CSS percentage string ("40%") parsed back to its number -- both
// glemy/game_breakout.gleam's rect_to_css (pure float math, e.g.
// 0.6 -. 0.4) and JS's own float subtraction can leave a tiny binary
// remainder, so every comparison here is a tolerance check, same
// reasoning as this project's other float-subtraction-derived test
// assertions (e.g. rect_to_css_converts_a_world_rect_into_a_css_box_test
// in test/glemy/game_breakout_test.gleam).
function parsePercent(value: string): number {
  const match = value.match(/^(-?[\d.]+)%$/);
  if (match === null) {
    fail(`expected a CSS percentage like "40%", got ${JSON.stringify(value)}`);
  }
  return Number(match[1]);
}

function assertNear(actual: number, expected: number, tolerance: number, what: string): void {
  if (Math.abs(actual - expected) > tolerance) {
    fail(`expected ${what} to be within ${tolerance} of ${expected}, got ${actual}`);
  }
}

const chromiumPath = findChromium();
const server = spawnDevServer(PORT);

try {
  const baseUrl = `http://localhost:${PORT}/breakout.html`;
  await waitForServer(baseUrl, 20);

  const browser: Browser = await launchGpuBrowser(chromiumPath);

  try {
    const page: Page = await browser.newPage();
    const pageErrors: string[] = [];
    page.on("pageerror", (err: Error) => pageErrors.push(err.message));
    await installCounters(page);

    await page.goto(baseUrl);
    await page.waitForTimeout(300);

    if (pageErrors.length > 0) {
      fail(`uncaught page errors: ${JSON.stringify(pageErrors)}`);
    }

    const framesBeforeMove = await frameCount(page);
    if (framesBeforeMove === 0) {
      fail(
        "requestAnimationFrame never fired within 300ms -- the game loop " +
          "isn't running at all",
      );
    }

    // Confirms glemy/game_breakout.gleam's main() reached
    // game_breakout_ffi.mjs's setScoreText/setStatusMessage/
    // setPaddleBox/createBrickElements with the real, computed starting
    // values -- not just that the pure Gleam math (format_score,
    // rect_to_css) is right on its own (that's already gleam
    // test-covered). breakout.new's starting paddle_x is bounds' own
    // center (50 of 0..100), paddle_half_width is 10, so the paddle
    // rect is x in [40, 60] -- left 40%, width 20%. paddle_margin_from_bottom
    // is 10, paddle_height is 3, so world y in [10, 13] -- CSS top 87%,
    // height 3%.
    const scoreText = await page.locator("#glemy-score").textContent();
    if (scoreText !== "Score: 0") {
      fail(`expected #glemy-score to read "Score: 0", got ${JSON.stringify(scoreText)}`);
    }
    const statusHidden = await page.locator("#glemy-status").isHidden();
    if (!statusHidden) {
      fail("expected #glemy-status to still be hidden before any win/loss");
    }
    const brickCount = await page.locator(".glemy-brick").count();
    if (brickCount !== 40) {
      fail(`expected 40 brick divs (5 rows x 8 columns), got ${brickCount}`);
    }

    const initialPaddleBox = await page
      .locator(PADDLE_SELECTOR)
      .evaluate((el) => {
        const style = (el as HTMLElement).style;
        return { left: style.left, top: style.top, width: style.width, height: style.height };
      });
    const tolerance = 0.01;
    assertNear(parsePercent(initialPaddleBox.left), 40, tolerance, "initial paddle left%");
    assertNear(parsePercent(initialPaddleBox.top), 87, tolerance, "initial paddle top%");
    assertNear(parsePercent(initialPaddleBox.width), 20, tolerance, "initial paddle width%");
    assertNear(parsePercent(initialPaddleBox.height), 3, tolerance, "initial paddle height%");

    // Real keyboard-driven paddle movement: glemy/games/breakout/paddle.speed
    // is 80 world-units/second and bounds.clamp_x clamps paddle_x into
    // [10, 90] (half_width 10, bounds 0..100) -- holding ArrowLeft for
    // 700ms of real wall-clock time moves the paddle at least
    // 80 * 0.7 = 56 world-units left, comfortably past the 40-unit
    // distance from the starting center (50) to the clamp floor (10),
    // so the paddle should land pinned at the clamp regardless of exact
    // per-frame dt jitter -- a deterministic assertion (CSS left 0%),
    // not a "did it move at all" one.
    await page.keyboard.down("ArrowLeft");
    await page.waitForTimeout(700);
    await page.keyboard.up("ArrowLeft");

    const framesAfterMove = await frameCount(page);
    if (framesAfterMove <= framesBeforeMove) {
      fail(
        "the game loop stopped advancing while ArrowLeft was held " +
          `(${framesBeforeMove} -> ${framesAfterMove} frames)`,
      );
    }

    const movedPaddleLeft = await page
      .locator(PADDLE_SELECTOR)
      .evaluate((el) => (el as HTMLElement).style.left);
    assertNear(
      parsePercent(movedPaddleLeft),
      0,
      tolerance,
      "paddle left% after holding ArrowLeft for 700ms",
    );

    // Real ball-brick collision: breakout.new starts the ball at world-y
    // ~16 heading straight up at vy 60, and the brick grid's bottom row
    // sits at world-y [57, 62] -- roughly 0.7s of real simulation time
    // away, already elapsed by the ArrowLeft hold above. Poll rather
    // than a fixed wait, so this isn't flaky against exact frame
    // timing.
    let sawBrickHit = false;
    for (let attempt = 0; attempt < 20; attempt++) {
      const hidden = await hiddenBrickCount(page);
      if (hidden > 0) {
        sawBrickHit = true;
        break;
      }
      await page.waitForTimeout(150);
    }
    if (!sawBrickHit) {
      fail(
        "no brick div was ever hidden -- a real ball-brick collision " +
          "never happened (or glemy/game_breakout_ffi.mjs's " +
          "hideBrickElement is broken)",
      );
    }

    const scoreAfterHit = await page.locator("#glemy-score").textContent();
    if (scoreAfterHit === "Score: 0") {
      fail(
        "a brick div was hidden but #glemy-score still reads \"Score: 0\" " +
          "-- glemy/game_breakout.gleam's score wiring looks broken",
      );
    }

    // Confirms glemy/game_breakout.gleam's loop actually reached
    // game_breakout_ffi.mjs's playBounceSound/playBrickSound (at least
    // one of them ran, from the wall bounce and/or the brick hit above)
    // -- same "confirm the real Web Audio path ran, not the sound
    // itself" reasoning as tools/browser_check.ts's own oscillator
    // check.
    const oscillatorStarts = await oscillatorStartCount(page);
    if (oscillatorStarts < 1) {
      fail(
        "expected at least one OscillatorNode.start() call after a wall " +
          `bounce and a brick hit, got ${oscillatorStarts} -- ` +
          "glemy/game_breakout.gleam's play_game_event path looks broken.",
      );
    }

    if (pageErrors.length > 0) {
      fail(`uncaught page errors: ${JSON.stringify(pageErrors)}`);
    }

    console.log(
      `PASS: requestAnimationFrame fired ${framesAfterMove} times, a real ` +
        "held ArrowLeft pinned the paddle at the left wall, a real " +
        "ball-brick collision hid a brick div and updated the score, " +
        `${oscillatorStarts} sound(s) played, zero page errors.`,
    );
  } finally {
    await browser.close();
  }
} finally {
  await stopDevServer(server);
}
