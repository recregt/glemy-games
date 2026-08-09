//// Tiers' own discrete size/merge-progression rules -- game-specific
//// data and logic, not core physics. Relocated here from the former
//// `glemy/pe/tier` (decision 0047; `pe` itself was later renamed to
//// `glemy/physics`, decision 0048): this module's entire content
//// interprets `Entity.kind` as "a tier" and derives radius/color/merge
//// behavior from it, which is exactly the kind of game-specific
//// interpretation `glemy/physics` itself never assumes (see
//// `physics/entity.gleam`'s own doc comment on `kind`) -- a different
//// game built on `glemy/physics` would use `kind` for something else
//// entirely, or not at all.
////
//// Pure, target-agnostic, no FFI: matches the `physics/vector2`,
//// `physics/entity`, `physics/bounds`, `physics/collision` pattern of
//// small, independently-tested primitive modules its own hub module
//// (`glemy/games/tiers`) composes together.
////
//// Tiers are plain data (a lookup table), deliberately kept to 6 for
//// this project's first playable version rather than the reference
//// game's 11 — extending the table later is a data change, not an
//// architecture change.

import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2
import glemy/random

/// How many tiers exist. Valid tiers are `0` up to (not including)
/// `tier_count`.
pub const tier_count = 6

/// The world-space radius entities of `tier` should have. The
/// authoritative direction is tier → radius, never the reverse.
///
/// Not a strict doubling (that would make the largest tier enormous
/// relative to the 100-unit-wide demo `Bounds`) — a gentler geometric-ish
/// progression, chosen so all 6 tiers stay visually distinct while the
/// biggest still comfortably fits the existing play area.
pub fn radius(tier: Int) -> Float {
  case tier {
    0 -> 4.0
    1 -> 6.0
    2 -> 9.0
    3 -> 13.0
    4 -> 18.0
    _ -> 24.0
  }
}

/// Whether `tier` is a real, in-range tier.
pub fn is_valid(tier: Int) -> Bool {
  tier >= 0 && tier < tier_count
}

/// The RGB color (each channel 0.0–1.0) entities of `tier` should
/// render as. Tier 0 is deliberately exactly `#(1.0, 0.0, 0.0)` — the
/// solid red every entity rendered as before tiers existed — so
/// existing pixel-red test assertions for default-tier entities keep
/// passing unchanged.
pub fn color(tier: Int) -> #(Float, Float, Float) {
  case tier {
    0 -> #(1.0, 0.0, 0.0)
    1 -> #(1.0, 0.5, 0.0)
    2 -> #(1.0, 1.0, 0.0)
    3 -> #(0.0, 1.0, 0.0)
    4 -> #(0.0, 0.3, 1.0)
    _ -> #(0.6, 0.0, 1.0)
  }
}

/// `color(tier)`, formatted as a CSS `rgb(...)` string -- for a plain
/// HTML/CSS UI element (e.g. `glemy/game_tiers`'s next-tier indicator) that
/// has no reason to go through the WebGPU entity-rendering pipeline for
/// a color swatch. `color` stays the single source of truth (decision
/// 0020) either way; this is purely a format conversion, not a second
/// place tier->color could drift out of sync.
/// ```gleam
/// color_css(0)
/// // -> "rgb(255, 0, 0)"
/// ```
pub fn color_css(tier: Int) -> String {
  let #(r, g, b) = color(tier)
  "rgb("
  <> channel_to_string(r)
  <> ", "
  <> channel_to_string(g)
  <> ", "
  <> channel_to_string(b)
  <> ")"
}

fn channel_to_string(channel: Float) -> String {
  int.to_string(float.round(channel *. 255.0))
}

/// The score earned when two entities of `tier` merge into `tier + 1`.
/// A gentle triangular-number-like progression (matching the reference
/// game's own scoring shape), tuned for this project's 6-tier scope.
/// Only meaningful for tiers that can actually merge away (`next(tier)`
/// is `Some`) — the highest tier never calls this.
pub fn score_for(tier: Int) -> Int {
  case tier {
    0 -> 1
    1 -> 3
    2 -> 6
    3 -> 10
    _ -> 15
  }
}

/// The tier two same-tier entities become when they merge, or `None`
/// if `tier` is already the highest tier (nothing to merge into).
pub fn next(tier: Int) -> Option(Int) {
  case tier + 1 < tier_count {
    True -> Some(tier + 1)
    False -> None
  }
}

/// Merges two same-tier entities into one entity of the next tier up.
/// Position is the midpoint of the two (correct, not just convenient:
/// same tier means same mass, so the midpoint *is* the true centroid).
/// Velocity is the average of the two — the equal-mass
/// perfectly-inelastic-collision result, consistent with
/// `glemy/physics/collision`'s mass model (decision 0018). Callers are
/// responsible for confirming `a.kind == b.kind` and that `next(a.kind)`
/// is `Some` before calling this — it doesn't check either itself.
pub fn merge(a: Entity, b: Entity) -> Entity {
  let new_tier = a.kind + 1
  Entity(
    position: vector2.scale(vector2.add(a.position, b.position), 0.5),
    velocity: vector2.scale(vector2.add(a.velocity, b.velocity), 0.5),
    radius: radius(new_tier),
    kind: new_tier,
    // A freshly merged entity is, physically, a new event -- restart
    // its sleep clock rather than inheriting either parent's.
    resting_time: 0.0,
  )
}

/// Which tiers the drop mechanic can hand the player next. Restricted to
/// the lower few tiers (not every tier up to `tier_count`) so early
/// drops stay simple, matching the reference game's own scope.
pub const droppable_tiers = [0, 1, 2]

/// Picks one tier out of `subset`, given `random` — a float expected to
/// be in `[0.0, 1.0)` (e.g. `float.random()`'s own documented range).
/// Deliberately takes `random` as a plain argument rather than calling
/// `float.random()` itself: this keeps tier selection pure and
/// fully deterministic-given-input, so callers (like
/// `glemy/games/tiers.tick`, and this module's own tests) can fix the
/// input and get an exact, repeatable answer instead of a genuinely
/// random one.
///
/// A thin wrapper over `glemy/random.pick` -- the actual index-selection
/// math is a Core utility now (decision 0049), generic over any list
/// element type; this function's own job is just supplying `subset` and
/// choosing tier `0` as the fallback for the (never actually hit --
/// `tick` always calls this with `droppable_tiers`, never an empty list)
/// empty-subset case, which `pick` itself has no sensible generic answer
/// for.
/// ```gleam
/// random_droppable(0.0, [0, 1, 2])
/// // -> 0
/// random_droppable(0.99, [0, 1, 2])
/// // -> 2
/// ```
pub fn random_droppable(random_value: Float, subset: List(Int)) -> Int {
  random.pick(random_value, subset) |> result.unwrap(0)
}
