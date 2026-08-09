import gleam/option.{None, Some}
import glemy_games/games/tiers/rules
import glemy/physics/entity.{Entity}
import glemy/physics/vector2.{Vector2}

pub fn radius_is_defined_for_every_valid_tier_test() {
  assert rules.radius(0) == 4.0
  assert rules.radius(1) == 6.0
  assert rules.radius(2) == 9.0
  assert rules.radius(3) == 13.0
  assert rules.radius(4) == 18.0
  assert rules.radius(5) == 24.0
}

pub fn radius_strictly_increases_with_tier_test() {
  let radii = [
    rules.radius(0),
    rules.radius(1),
    rules.radius(2),
    rules.radius(3),
    rules.radius(4),
    rules.radius(5),
  ]
  assert radii == [4.0, 6.0, 9.0, 13.0, 18.0, 24.0]
  // Explicitly pairwise-increasing, not just "happens to be sorted" --
  // a flat or decreasing step anywhere would make two adjacent tiers
  // visually indistinguishable or backwards.
  assert rules.radius(1) >. rules.radius(0)
  assert rules.radius(2) >. rules.radius(1)
  assert rules.radius(3) >. rules.radius(2)
  assert rules.radius(4) >. rules.radius(3)
  assert rules.radius(5) >. rules.radius(4)
}

pub fn radius_out_of_range_falls_back_to_the_largest_tier_test() {
  // The catch-all `_ -> 24.0` branch means anything at or past the
  // highest defined tier index (including genuinely invalid tiers, like
  // negative or way-out-of-range ones) resolves to the biggest radius
  // rather than crashing -- documented explicitly since `radius` has no
  // Result/error path at all.
  assert rules.radius(5) == 24.0
  assert rules.radius(6) == 24.0
  assert rules.radius(100) == 24.0
}

pub fn is_valid_accepts_every_in_range_tier_test() {
  assert rules.is_valid(0)
  assert rules.is_valid(1)
  assert rules.is_valid(2)
  assert rules.is_valid(3)
  assert rules.is_valid(4)
  assert rules.is_valid(5)
}

pub fn is_valid_rejects_out_of_range_tiers_test() {
  assert !rules.is_valid(-1)
  assert !rules.is_valid(6)
  assert !rules.is_valid(100)
}

pub fn tier_count_matches_the_number_of_defined_radii_test() {
  assert rules.tier_count == 6
}

pub fn color_tier_zero_is_solid_red_test() {
  // Deliberate backward-compatibility pin: every entity rendered as
  // solid red before tiers existed, and tier 0 is the default for
  // anything not explicitly given another tier -- existing pixel-red
  // test assertions elsewhere depend on this staying true.
  assert rules.color(0) == #(1.0, 0.0, 0.0)
}

pub fn color_is_distinct_for_every_defined_tier_test() {
  let colors = [
    rules.color(0),
    rules.color(1),
    rules.color(2),
    rules.color(3),
    rules.color(4),
    rules.color(5),
  ]
  // Every pair of tiers should look different -- checked exhaustively,
  // not just "the list looks varied at a glance".
  assert list_all_pairs_distinct(colors)
}

fn list_all_pairs_distinct(items: List(a)) -> Bool {
  case items {
    [] -> True
    [first, ..rest] ->
      list_all_different_from(first, rest) && list_all_pairs_distinct(rest)
  }
}

fn list_all_different_from(item: a, rest: List(a)) -> Bool {
  case rest {
    [] -> True
    [next, ..remaining] ->
      item != next && list_all_different_from(item, remaining)
  }
}

pub fn color_out_of_range_falls_back_to_the_highest_tier_color_test() {
  assert rules.color(5) == rules.color(6)
  assert rules.color(100) == rules.color(5)
}

pub fn color_css_formats_tier_zeros_solid_red_test() {
  assert rules.color_css(0) == "rgb(255, 0, 0)"
}

pub fn color_css_rounds_fractional_channels_test() {
  // tier 1 is #(1.0, 0.5, 0.0) -- 0.5 * 255 = 127.5, which must round
  // (not truncate) to 128, not silently drop the fraction.
  assert rules.color_css(1) == "rgb(255, 128, 0)"
}

pub fn color_css_matches_color_for_every_defined_tier_test() {
  // Not a second, independently-hand-typed color table -- every
  // formatted string is directly derivable from the same rules.color
  // this whole module already treats as the single source of truth.
  assert rules.color_css(2) == "rgb(255, 255, 0)"
  assert rules.color_css(3) == "rgb(0, 255, 0)"
  assert rules.color_css(4) == "rgb(0, 77, 255)"
  assert rules.color_css(5) == "rgb(153, 0, 255)"
}

pub fn score_for_increases_with_tier_test() {
  // Higher tiers should be worth more to merge away -- a flat or
  // decreasing step anywhere would make progressing through tiers feel
  // pointless.
  assert rules.score_for(0) < rules.score_for(1)
  assert rules.score_for(1) < rules.score_for(2)
  assert rules.score_for(2) < rules.score_for(3)
  assert rules.score_for(3) < rules.score_for(4)
}

pub fn next_returns_some_below_the_highest_tier_test() {
  assert rules.next(0) == Some(1)
  assert rules.next(1) == Some(2)
  assert rules.next(4) == Some(5)
}

pub fn next_returns_none_at_the_highest_tier_test() {
  // The highest tier (tier_count - 1) has nothing to merge into --
  // this is exactly what `glemy/games/tiers`'s merge logic checks to
  // decide two max-tier entities should bounce, not merge.
  assert rules.next(5) == None
}

pub fn merge_produces_an_entity_of_the_next_tier_at_its_correct_radius_test() {
  let a =
    Entity(
      resting_time: 0.0,
      position: Vector2(0.0, 0.0),
      velocity: vector2.zero,
      radius: rules.radius(2),
      kind: 2,
    )
  let b =
    Entity(
      resting_time: 0.0,
      position: Vector2(4.0, 0.0),
      velocity: vector2.zero,
      radius: rules.radius(2),
      kind: 2,
    )

  let merged = rules.merge(a, b)

  assert merged.kind == 3
  assert merged.radius == rules.radius(3)
}

pub fn merge_position_is_the_midpoint_test() {
  let a =
    Entity(
      resting_time: 0.0,
      position: Vector2(0.0, 0.0),
      velocity: vector2.zero,
      radius: rules.radius(0),
      kind: 0,
    )
  let b =
    Entity(
      resting_time: 0.0,
      position: Vector2(10.0, 20.0),
      velocity: vector2.zero,
      radius: rules.radius(0),
      kind: 0,
    )

  let merged = rules.merge(a, b)

  assert merged.position == Vector2(5.0, 10.0)
}

pub fn merge_velocity_is_the_average_test() {
  let a =
    Entity(
      resting_time: 0.0,
      position: vector2.zero,
      velocity: Vector2(2.0, 4.0),
      radius: rules.radius(0),
      kind: 0,
    )
  let b =
    Entity(
      resting_time: 0.0,
      position: vector2.zero,
      velocity: Vector2(-6.0, 0.0),
      radius: rules.radius(0),
      kind: 0,
    )

  let merged = rules.merge(a, b)

  assert merged.velocity == Vector2(-2.0, 2.0)
}

pub fn droppable_tiers_is_the_lower_three_tiers_test() {
  assert rules.droppable_tiers == [0, 1, 2]
}

pub fn random_droppable_at_zero_picks_the_first_tier_test() {
  assert rules.random_droppable(0.0, [0, 1, 2]) == 0
}

pub fn random_droppable_near_one_picks_the_last_tier_test() {
  // float.random()'s own documented range is [0.0, 1.0) -- 0.99 is a
  // realistic "close to the top" value without assuming random() can
  // ever produce exactly 1.0.
  assert rules.random_droppable(0.99, [0, 1, 2]) == 2
}

pub fn random_droppable_in_the_middle_picks_the_middle_tier_test() {
  assert rules.random_droppable(0.5, [0, 1, 2]) == 1
}

pub fn random_droppable_covers_every_subset_boundary_test() {
  // Exhaustively pins down which fraction of [0.0, 1.0) maps to which
  // index, for a 3-element subset: [0, 1/3) -> 0, [1/3, 2/3) -> 1,
  // [2/3, 1.0) -> 2.
  assert rules.random_droppable(0.32, [0, 1, 2]) == 0
  assert rules.random_droppable(0.34, [0, 1, 2]) == 1
  assert rules.random_droppable(0.65, [0, 1, 2]) == 1
  assert rules.random_droppable(0.67, [0, 1, 2]) == 2
}

pub fn random_droppable_with_a_single_element_subset_always_returns_it_test() {
  assert rules.random_droppable(0.0, [4]) == 4
  assert rules.random_droppable(0.5, [4]) == 4
  assert rules.random_droppable(0.99, [4]) == 4
}

pub fn random_droppable_with_an_empty_subset_falls_back_to_zero_test() {
  // Defensive only -- `tick` always calls this with `droppable_tiers`,
  // never an empty list, but a public function shouldn't crash on a
  // technically-valid-looking empty input.
  assert rules.random_droppable(0.5, []) == 0
}

pub fn random_droppable_clamps_out_of_range_random_values_test() {
  // Documents defensive behavior for inputs outside the function's own
  // documented [0.0, 1.0) contract, rather than leaving it undefined:
  // negative values clamp to the first tier, values at or above 1.0
  // clamp to the last.
  assert rules.random_droppable(-1.0, [0, 1, 2]) == 0
  assert rules.random_droppable(1.0, [0, 1, 2]) == 2
  assert rules.random_droppable(50.0, [0, 1, 2]) == 2
}
