# Progress tracker

Where we are now, and what changed. Read this at the start of every session.

## How to update

At the end of every session that changed code or docs, in order:
1. Update the status of each task touched.
2. Add a session log entry: what was done, what is next.
3. Add decisions to the decisions log, with the reason. Update the locked decisions table in `spec.md` section 4 when a locked decision changes.
4. Add new questions or blockers to open questions.
5. If a task split, add the new tasks here.
6. If a file moved or was deleted, update `project-structure.md` and add a file changes row.
7. If a doc changed, add a doc changes row.
8. If a log passes 10 rows, move the oldest to `docs/archive/progress-tracker-archive-YYYY-MM.md` and link it.

Status values: `Not started`, `In progress`, `In review`, `Blocked` (reason in open questions), `Done` (the done-when criteria pass).

## Current phase

Phase 0: docs. Status: Done on 2026-11-05 (docs written, awaiting Blair's read-through). Next phase: M0 risk spikes.

## Tasks

Everything is simulated first (decision D17). Acceptance items are in `spec.md` section 18. Each item is owned by one milestone.

| ID | Task | Owner | Status | Done when |
| --- | --- | --- | --- | --- |
| M0-S1 | RAM-disk exFAT harness: prove writer and reader `F_NOCACHE`, remount, stale-cache case, measure hash and read speeds, tune the cache guard | Blair and Claude | Not started | Written results in the tracker, harness script in `Scripts/` |
| M0-S2 | DiskArbitration listing and the D12 filter, tested on disk images and the RAM disk | Blair and Claude | Not started | Filter shows the RAM disk, hides images and the boot volume |
| M0-S3 | IOKit: hub in path, hub depth, negotiated speed, port location | Blair and Claude | Blocked | Needs a real USB device (open question 8). Property names confirmed in `architecture.md` |
| M0-S4 | Signing, privacy prompts, notification permission, menu bar item | Blair and Claude | Not started | One build with stable signing, no repeat prompts |
| M0-S5 | Sleep assertion with `ProcessInfo.beginActivity` and wake detection | Blair and Claude | Not started | `pmset -g assertions` shows it, wake event seen |
| M1 | Core engine in `USBVerifyCore` with fake drive and fault hooks | Claude | Not started | Acceptance items 2 to 9, 14, 15 pass on the fake drive |
| M2 | App shell: Drives, copy flow, review sheet, progress, Jobs, results | Claude | Not started | Items 1 and 10 pass. A full copy of a test file through the UI on the fake drive and the RAM disk |
| M3 | Verify-only, History, connection UI, route comparison, log | Claude | Not started | Item 17 passes. History and route views work on simulated data |
| M4 | Format, capacity test, `._` cleanup, menu bar, notifications, sleep block | Claude | Not started | Items 11, 12, 13, 16 pass on fakes |
| M5 | Real-hardware proof | Blair | Not started | Deferred by choice. Needs a drive Blair can wipe. Item 18, a re-run of items 1 to 17, Format rights, remount on USB, S3 |

## Decisions log

| Date | Decision | Reason | Docs updated |
| --- | --- | --- | --- |
| 2026-11-05 | Round 1: hub or adapter is the suspect. Strict default and Quick mode. Stop on failure with Keep scanning. v1 gets verify-only, format, capacity test, `._` cleanup. Files only. Temp name then rename. Menu bar status. | Corruption seen through a hub. Immediate read-back can pass on a bad drive. | spec.md 4, 8, 9 |
| 2026-11-05 | Round 2: sidebar layout, both capacity test modes, format guard with BSD id, manual resume. All four connection-awareness features. | Paused jobs and history need a home. Hub is the main suspect. | spec.md 6, 10, 12, 13, 15 |
| 2026-11-05 | Round 3: list all external volumes. exFAT and FAT32 only. Busy unmount waits and asks. Format falls back to the admin prompt. | Research: removable flag fails for SSDs, raw device is denied, admin need unproven. | spec.md 7, 8, 12; architecture.md |
| 2026-11-05 | Round 4: simulate everything first, real-drive tests later. Risk spikes first. Five docs only, README at root. | Blair's choice. Khan holds data. Blair asked for minimal docs. | all |
| 2026-11-05 | Defaults set by Claude, open to change: 64 MiB chunk, 3 retries, SHA-256, one active job, review sheet, last 4 chunks re-read on resume, deployment target macOS 27.2. | Matches draft 1 or is the simplest safe choice. | spec.md 4, 8, 10 |

## Open questions

| # | Question | Owner | Date | Status |
| --- | --- | --- | --- | --- |
| 1 | Cache guard threshold (default 1 GB/s) | Claude, in S1 | 2026-11-05 | Open |
| 2 | IOKit property names for hub depth and speed | Claude, in S3 | 2026-11-05 | Open |
| 3 | Does Format need admin rights on real USB? | Blair, in M5 | 2026-11-05 | Deferred to M5 by choice |
| 4 | Does unmount and mount clear the cache on real USB, and does `F_FULLFSYNC` reach the controller? | Blair, in M5 | 2026-11-05 | Deferred to M5 by choice |
| 5 | Test framework and lint tool | Claude, in M1 | 2026-11-05 | Open |
| 6 | Is the 4-chunk re-read on resume enough? | Blair | 2026-11-05 | Open |
| 7 | Exact exFAT and FAT32 file name rules to enforce | Claude, in M1 | 2026-11-05 | Open |
| 8 | May Claude run read-only probes of Khan's USB properties (IOKit only, no file reads or writes) in M0-S3, or wait for M5? | Blair | 2026-11-05 | Open |

## Session log (newest first)

| Date | Who | What was done | Next |
| --- | --- | --- | --- |
| 2026-11-05 | Blair, Claude | Grilled draft 1 in 4 rounds. A research agent checked cache, remount, erase, and drive-filter facts. Moved `SPEC.md` to `docs/spec.md` and rewrote it. Wrote architecture, structure, tracker, README. | Blair reads the docs. Then start M0 spikes. |

## File changes log

| Date | Change |
| --- | --- |
| 2026-11-05 | Moved `SPEC.md` to `docs/spec.md`. Created `README.md`, `docs/architecture.md`, `docs/project-structure.md`, `docs/progress-tracker.md`. |

## Doc changes log

| Date | Change |
| --- | --- |
| 2026-11-05 | `docs/spec.md` rewritten: 18 locked decisions, new sections for verify-only, format, capacity test, connection awareness, history. Draft 1 open questions all answered. |
| 2026-11-05 | Only 5 docs, not the full 14 (Blair's choice). The lint will report the other docs as missing. That is expected. |

## Notes for later

- Run `f3write` and `f3read` on Khan to test the fake-capacity theory before the app exists. It writes about 32 GB of test files into free space and deletes them. Blair decides.
- Back up Khan before any capacity test. A fake-capacity drive can overwrite existing files.
- Folder copies are planned for v1.1.
- The FSKit exFAT driver is a suspect. Log it on every run and compare with other drives.
- Draft 1 is saved only in the session scratchpad. The decisions are all in this tracker and in `spec.md`.
