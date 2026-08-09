// Manual, on-demand real-browser verification for glemy/game_platformer
// (platformer.html's requestAnimationFrame runner) -- the platformer
// counterpart to tools/browser_check_breakout.ts (see that file's own
// header comment, and tools/browser_check_shared.ts's, for why this is
// a separate script sharing only the launch/dev-server bootstrap).
//
// What this checks that `gleam test --target javascript` structurally
// can't (real requestAnimationFrame, a real <canvas>, real keyboard
// events reaching glemy/io): the RAF loop actually runs; a real held
// ArrowRight keypress actually moves the real player entity in world
// space (confirmed via the same captured-GPU-uniform technique
// tools/browser_check.ts already established for Tiers' own
// click-to-spawn check -- the player renders through WebGPU, not a CSS
// div, so there's no DOM position to read directly); a real held space
// keypress while grounded actually launches the player upward in world
// space; and a real, unassisted walk off the starting platform's edge
// reaches a real `Lost` status end to end.
//
// Requires a Playwright-downloaded Chromium to already exist locally,
// same one-time setup as tools/browser_check.ts: `npx --yes playwright
// install chromium`. Run with `deno task browser-check-platformer`.

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

const PORT = 8768;

/**
 * Same real-API-instrumentation approach as tools/browser_check.ts's
 * own installFrameCounters: counts real GPUCanvasContext.configure
 * calls (the RAF loop confirmation) and real OscillatorNode.start()
 * calls (jump/land sounds actually played), and captures every 2-float
 * uniform buffer's contents into `__glemyCapturedVec2s` -- the player's
 * own world-space center is one of these each frame (alongside the
 * play field's own bounds min/max corners), which is how this script
 * confirms real keyboard input actually moved the player in world
 * space without needing canvas pixel readback (a documented, upstream
 * headless-Chrome limitation on Linux, see tools/browser_check.ts's
 * own comment for the citation).
 */
async function installCounters(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const w = window as unknown as {
      __glemyFrameCount: number;
      __glemyOscillatorStartCount: number;
      __glemyCapturedVec2s: [number, number][];
    };
    w.__glemyFrameCount = 0;
    w.__glemyOscillatorStartCount = 0;
    w.__glemyCapturedVec2s = [];

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

/** Clears the captured-vec2 log so a later check only sees fresh samples. */
async function clearCapturedVec2s(page: Page): Promise<void> {
  await page.evaluate(() => {
    (window as unknown as { __glemyCapturedVec2s: [number, number][] }).__glemyCapturedVec2s =
      [];
  });
}

/**
 * Whether any captured 2-float uniform buffer has an x component
 * exceeding `threshold` -- used to confirm a real rightward move
 * genuinely happened in world space. `threshold` is chosen well clear
 * of both the player's own starting x and the play field's own bounds
 * corners (0/100), so this can't accidentally match a stray bounds
 * capture instead of a real player-position one.
 */
async function anyCapturedXExceeds(page: Page, threshold: number): Promise<boolean> {
  return await page.evaluate((t) => {
    const captured = (
      window as unknown as { __glemyCapturedVec2s: [number, number][] }
    ).__glemyCapturedVec2s;
    return captured.some(([x]) => x > t);
  }, threshold);
}

/** Same reasoning as `anyCapturedXExceeds`, for the y axis (jump height). */
async function anyCapturedYExceeds(page: Page, threshold: number): Promise<boolean> {
  return await page.evaluate((t) => {
    const captured = (
      window as unknown as { __glemyCapturedVec2s: [number, number][] }
    ).__glemyCapturedVec2s;
    return captured.some(([, y]) => y > t);
  }, threshold);
}

const chromiumPath = findChromium();
const server = spawnDevServer(PORT);

try {
  const baseUrl = `http://localhost:${PORT}/platformer.html`;
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

    const statusHidden = await page.locator("#glemy-status").isHidden();
    if (!statusHidden) {
      fail("expected #glemy-status to still be hidden before any win/loss");
    }
    const platformCount = await page.locator(".glemy-platform").count();
    if (platformCount !== 6) {
      fail(`expected 6 platform divs, got ${platformCount}`);
    }

    // games/platformer.new starts the player centered on the first
    // platform (x in [5, 35], center 20.0). Holding ArrowRight for real
    // wall-clock time at move_speed (35 world-units/s) should carry it
    // well past x=28 within well under a second -- comfortably clear of
    // both the starting x (20.0) and the bounds corners (0/100) any
    // captured vec2 might otherwise coincidentally match.
    await clearCapturedVec2s(page);
    await page.keyboard.down("ArrowRight");
    await page.waitForTimeout(400);
    await page.keyboard.up("ArrowRight");

    const framesAfterMove = await frameCount(page);
    if (framesAfterMove <= framesBeforeMove) {
      fail(
        "the game loop stopped advancing while ArrowRight was held " +
          `(${framesBeforeMove} -> ${framesAfterMove} frames)`,
      );
    }
    if (!(await anyCapturedXExceeds(page, 28.0))) {
      fail(
        "no captured player position moved past world-x 28 after holding " +
          "ArrowRight for 400ms -- the real keyboard-driven move path " +
          "(glemy/io.is_key_down wired into glemy/game_platformer's loop) " +
          "looks broken.",
      );
    }

    // A held space jump while grounded should send the player upward
    // (jump_speed 70, gravity -180) well past its resting y (~15.0,
    // platform 0's top at y=10 plus player_radius 2.5, plus a little
    // headroom from the ArrowRight move above) -- checked well before
    // gravity has time to arc it back down to platform height.
    await clearCapturedVec2s(page);
    await page.keyboard.down(" ");
    await page.waitForTimeout(150);
    await page.keyboard.up(" ");

    if (!(await anyCapturedYExceeds(page, 20.0))) {
      fail(
        "no captured player position rose past world-y 20 after holding " +
          "space for 150ms while grounded -- the real jump path looks broken.",
      );
    }

    // Confirms glemy/game_platformer.gleam's loop actually reached
    // game_platformer_ffi.mjs's playJumpSound for the jump above --
    // same "confirm the real Web Audio path ran, not the sound itself"
    // reasoning as tools/browser_check.ts's own oscillator check.
    const oscillatorStarts = await oscillatorStartCount(page);
    if (oscillatorStarts < 1) {
      fail(
        "expected at least one OscillatorNode.start() call after a real " +
          `jump, got ${oscillatorStarts} -- glemy/game_platformer.gleam's ` +
          "play_game_event path looks broken.",
      );
    }

    // Real, unassisted terminal-status check: hold ArrowLeft continuously
    // from a fresh page load (no jump) -- the player walks off the
    // starting platform's own left edge (x=5, roughly 0.36s away at
    // move_speed) and free-falls straight past bounds.min.y (roughly
    // another 0.37s under gravity), reaching a real Lost status within
    // about 0.75s. Reloaded fresh rather than reusing the page above, so
    // the earlier rightward move/jump can't put the player somewhere
    // this deterministic walk-left-and-fall math doesn't account for.
    await page.reload();
    await page.waitForTimeout(300);
    await page.keyboard.down("ArrowLeft");
    await page.waitForTimeout(2000);
    await page.keyboard.up("ArrowLeft");

    const statusText = await page.locator("#glemy-status").textContent();
    const statusVisible = await page.locator("#glemy-status").isVisible();
    if (!statusVisible || statusText !== "You fell!") {
      fail(
        `expected #glemy-status to read "You fell!" and be visible after ` +
          `walking off the starting platform, got visible=${statusVisible} ` +
          `text=${JSON.stringify(statusText)} -- the real fall-death path ` +
          "looks broken.",
      );
    }

    if (pageErrors.length > 0) {
      fail(`uncaught page errors: ${JSON.stringify(pageErrors)}`);
    }

    console.log(
      `PASS: requestAnimationFrame fired ${framesAfterMove} times, a real ` +
        "held ArrowRight moved the player in world space, a real held " +
        "space jump raised it in world space, " +
        `${oscillatorStarts} sound(s) played, and walking off the ` +
        "starting platform reached a real \"You fell!\" status, zero page errors.",
    );
  } finally {
    await browser.close();
  }
} finally {
  await stopDevServer(server);
}
