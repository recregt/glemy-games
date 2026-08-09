//// Bricks: static rectangular obstacles the ball destroys on contact --
//// game-specific data and logic, not core physics (decision 0052).
//// Built on `glemy/physics/rect`'s detection math (`overlaps`,
//// `penetration_axis`), which is Core; what a brick *is* and what
//// happens when the ball hits one stays entirely this game's own
//// concern.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import glemy/physics/rect.{type Rect, Horizontal, Rect, Vertical}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2.{Vector2}

/// A single brick: its rectangle, how much destroying it is worth, and
/// a stable `id` assigned once by `grid` -- needed so a renderer can key
/// a DOM element (or any other per-brick resource) to a *specific*
/// brick across frames. A brick's position in `List(Brick)` isn't stable
/// for this purpose: destroying an earlier brick shifts every later
/// brick's list index, which would silently make a renderer update the
/// wrong element if it used list position as a key instead. A destroyed
/// brick is removed from the list entirely, not flagged -- matching how
/// `glemy/physics/collision_sweep`'s `Consume` already makes entities
/// disappear by omission rather than an `alive: Bool` field.
pub type Brick {
  Brick(id: Int, rect: Rect, score: Int)
}

/// Lays out `rows` × `columns` bricks, evenly spaced (`spacing` between
/// bricks and from the play field's left/right edges), starting
/// `top_margin` below `bounds.max.y`, each `brick_height` tall and worth
/// `score_per_brick`. Column width is derived from `bounds`' own width
/// so the grid always spans the full play field regardless of its size.
/// `id`s are assigned `row * columns + column`, in the same row-major
/// order the bricks themselves come back in -- stable identity, not a
/// promise about the order the returned list stays in as bricks are
/// removed (it doesn't need one; only `id` needs to stay stable).
/// ```gleam
/// grid(
///   rows: 1, columns: 2,
///   bounds: Rect(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0)),
///   top_margin: 10.0, brick_height: 5.0, spacing: 2.0, score_per_brick: 10,
/// )
/// // -> two Bricks (ids 0 and 1), each 46.0 wide, side by side with a
/// // 2.0 gap and 2.0 margin on both outer edges, top edge at world y = 90.0
/// ```
pub fn grid(
  rows rows: Int,
  columns columns: Int,
  bounds bounds: Rect,
  top_margin top_margin: Float,
  brick_height brick_height: Float,
  spacing spacing: Float,
  score_per_brick score_per_brick: Int,
) -> List(Brick) {
  let field_width = bounds.max.x -. bounds.min.x
  let brick_width =
    { field_width -. spacing *. int.to_float(columns + 1) }
    /. int.to_float(columns)
  let top = bounds.max.y -. top_margin

  list.repeat(Nil, rows)
  |> list.index_map(fn(_, row) {
    list.repeat(Nil, columns)
    |> list.index_map(fn(_, column) {
      let x =
        bounds.min.x
        +. spacing
        +. int.to_float(column) *. { brick_width +. spacing }
      let y = top -. int.to_float(row) *. { brick_height +. spacing }
      Brick(
        id: row * columns + column,
        rect: Rect(
          min: Vector2(x, y -. brick_height),
          max: Vector2(x +. brick_width, y),
        ),
        score: score_per_brick,
      )
    })
  })
  |> list.flatten
}

/// Reflects `ball`'s velocity off `brick_rect`, flipping whichever
/// velocity component `rect.penetration_axis` says was hit. No position
/// correction (contrast `glemy/games/breakout/paddle.reflect`): the
/// brick this collided with is about to be removed from the game
/// entirely by `resolve_first_hit`, so there's nothing left for the
/// ball to keep overlapping next frame.
pub fn reflect(ball: Entity, brick_rect: Rect) -> Entity {
  case rect.penetration_axis(ball, brick_rect) {
    Horizontal ->
      Entity(..ball, velocity: Vector2(float.negate(ball.velocity.x), ball.velocity.y))
    Vertical ->
      Entity(..ball, velocity: Vector2(ball.velocity.x, float.negate(ball.velocity.y)))
  }
}

/// The outcome of a resolved brick hit: the ball's new (reflected)
/// state, the bricks left after removing the one that was hit, its
/// score, and its stable `id` -- a renderer needs the `id` specifically
/// to know which DOM element (or other per-brick resource) to retire,
/// since list position isn't a safe key (see `Brick`'s own doc comment).
pub type Hit {
  Hit(ball: Entity, remaining: List(Brick), score: Int, destroyed_id: Int)
}

/// Finds the first brick in `bricks` (list order) that `ball` overlaps,
/// reflects the ball off it (`reflect`), and removes that brick from
/// the list -- resolving only that one hit, even if `ball`'s position
/// this frame happens to overlap more than one brick at once (a large
/// `dt`, or corner-adjacent bricks): the rest are left untouched, to be
/// checked again next frame. Same "resolve one interaction and move on"
/// philosophy `glemy/physics/collision_sweep.resolve_target_against_rest`'s
/// own doc comment already states for entity-entity collisions.
///
/// `None` if `ball` doesn't overlap any brick in `bricks` at all.
pub fn resolve_first_hit(ball: Entity, bricks: List(Brick)) -> Option(Hit) {
  case bricks {
    [] -> None
    [first, ..rest] ->
      case rect.overlaps(ball, first.rect) {
        True ->
          Some(Hit(
            ball: reflect(ball, first.rect),
            remaining: rest,
            score: first.score,
            destroyed_id: first.id,
          ))
        False ->
          case resolve_first_hit(ball, rest) {
            Some(hit) -> Some(Hit(..hit, remaining: [first, ..hit.remaining]))
            None -> None
          }
      }
  }
}
