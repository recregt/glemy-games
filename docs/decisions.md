# Decision log

`docs/decisions.jsonl` is this repo's own running log of technical
decisions, in the exact same schema glemy uses — see glemy's own
`docs/decisions.md` for the full field-by-field schema and the reasoning
behind this format (JSONL over prose ADRs, when an entry is warranted,
etc.). That reasoning isn't duplicated here; only the parts specific to
this repo are.

This log starts empty at the point glemy-games was split out of glemy —
every decision from before the split (including the split decision
itself) lives in glemy's own `docs/decisions.jsonl`, not duplicated
here.

## How to add an entry

There's no separate copy of the `tools/decisions` CLI in this repo —
use glemy's own copy, pointed at this repo's log file via its optional
second argument (both repos are expected to be checked out as siblings
on the same machine):

```sh
cd ../glemy/tools/decisions
gleam run -- decision <draft.json> ../../../glemy-games/docs/decisions.jsonl
```
