# USB Verify Copy

A native macOS app (SwiftUI) that copies large files to a USB drive and proves the copy matches the source. It verifies chunks while writing, then remounts the drive and re-reads everything, and it shows how the drive is connected.

## Doc map

| File | Answers |
| --- | --- |
| `README.md` | Where do I start, and which doc answers my question? |
| `docs/spec.md` | What does the app do, what is decided, and when is it done? |
| `docs/architecture.md` | How is it built, how do the parts talk, what was checked on this Mac? |
| `docs/project-structure.md` | Where does each file live? |
| `docs/progress-tracker.md` | Where are we now, and what changed? |

This table is the only doc map in the project.

## Reading order

1. This file.
2. `docs/progress-tracker.md` for the current phase and open questions.
3. `docs/spec.md` for behavior and locked decisions.
4. `docs/architecture.md` when you build or change a module.
5. `docs/project-structure.md` when you add or move a file.

## Status

Docs are done. No code yet. Next: milestone M0 risk spikes, all simulated. See the tracker.

## Keeping docs true

- Truth order: the user's instruction, then verified code and config, then docs. For facts, the code wins and the doc is fixed. For intent, ask.
- A doc changes in the same change as the code or decision it describes. Delete a section that no longer applies.
- Keep the latest 10 entries in each tracker log. Move older ones to `docs/archive/`.
- Write in simple English. No em-dashes, no emoji.
