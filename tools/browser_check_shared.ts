// Shared real-browser bootstrap for `tools/browser_check.ts` and
// `tools/browser_check_breakout.ts` -- extracted once a second game
// genuinely needed the exact same Chromium-locating/dev-server/launch-flag
// logic (`browser_check.ts`'s own header comment originally said a second
// game gets its own *equivalent check*, not this file extended to cover
// both -- true of the actual game-specific assertions below, but the
// launch/server bootstrap around them was identical, byte for byte, and
// this project's own standing rule is to extract at the *second* real
// caller, not the first (same reasoning `glemy/games/tiers` and
// `glemy/games/breakout` both composing `physics/entity`/
// `collision_sweep` directly, rather than a guessed-at shared abstraction,
// already applies -- there, physics primitives; here, browser-launch
// plumbing).
//
// See `browser_check.ts`'s own header comment for why this category of
// tool exists at all (decision 0008/0012) and isn't part of `gleam test`.

/// <reference lib="dom" />

import { chromium, type Browser } from "npm:playwright-core@1.62.1";

export const REPO_ROOT = new URL("..", import.meta.url).pathname;

export function findChromium(): string {
  const home = Deno.env.get("HOME");
  if (home === undefined) {
    throw new Error("$HOME is not set -- can't locate the Playwright cache.");
  }
  const cacheDir = `${home}/.cache/ms-playwright`;
  let entries: Deno.DirEntry[] = [];
  try {
    entries = [...Deno.readDirSync(cacheDir)];
  } catch {
    entries = [];
  }
  for (const entry of entries) {
    if (entry.isDirectory && entry.name.startsWith("chromium-")) {
      const candidate = `${cacheDir}/${entry.name}/chrome-linux64/chrome`;
      try {
        Deno.statSync(candidate);
        return candidate;
      } catch {
        // keep looking
      }
    }
  }
  throw new Error(
    "No Playwright Chromium install found under ~/.cache/ms-playwright. " +
      "Run `npx --yes playwright install chromium` once, then retry.",
  );
}

export function fail(message: string): never {
  console.error(`FAIL: ${message}`);
  Deno.exit(1);
}

export async function waitForServer(url: string, attempts: number): Promise<void> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      const res = await fetch(url);
      await res.body?.cancel();
      if (res.ok) return;
    } catch {
      // not up yet
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  fail(`dev server never came up at ${url}`);
}

// Matches the documented dev-server invocation (docs/development-plan.jsonl
// RM-003, decision 0026) -- without --header Cache-Control: no-cache,
// file-server sets no Cache-Control at all, and a version-skewed cached
// .mjs file is a real, previously-observed way for the game to silently
// fail.
export function spawnDevServer(port: number): Deno.ChildProcess {
  return new Deno.Command("deno", {
    args: [
      "run",
      "--allow-net",
      "--allow-read",
      "jsr:@std/http/file-server",
      "--port",
      String(port),
      "--quiet",
      "--header",
      "Cache-Control: no-cache",
      REPO_ROOT,
    ],
    stdout: "null",
    stderr: "null",
  }).spawn();
}

export async function stopDevServer(server: Deno.ChildProcess): Promise<void> {
  // The dev-server child can have already exited on its own by the time
  // we get here (observed in practice, not just theoretical) -- kill()
  // throws in that case, which would otherwise mask a real PASS above
  // with a spurious crash.
  try {
    server.kill();
  } catch {
    // already terminated
  }
  await server.status;
}

// Root cause of the flag combination below (see browser_check.ts's own
// header comment for the full research trail, decisions 0011/0012):
// headless Chromium's WebGPU/Vulkan backend needs this specific,
// undocumented-by-trial-and-error set, confirmed against Chrome for
// Developers' own headless-WebGPU guide, not the more commonly-guessed
// --enable-unsafe-swiftshader/--use-vulkan=swiftshader flags.
export async function launchGpuBrowser(chromiumPath: string): Promise<Browser> {
  return await chromium.launch({
    executablePath: chromiumPath,
    headless: true,
    args: [
      "--headless=new",
      "--no-sandbox",
      "--use-angle=vulkan",
      "--enable-features=Vulkan",
      "--disable-vulkan-surface",
      "--enable-unsafe-webgpu",
    ],
  });
}
