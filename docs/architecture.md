# Architecture

How USB Verify is built. Product behavior is in `spec.md`. File layout is in `project-structure.md`.

## Stack (locked)

- Swift 6.4, SwiftUI, Xcode 27.0, macOS 27.2 (build 26B123), Apple silicon.
- One Xcode app target plus one Swift package, `USBVerifyCore`, for all logic that needs no UI.
- Hash: SHA-256, streaming (CryptoKit). Hash speed is expected to be far above USB speed. Measure it in spike S1.
- I/O: POSIX file descriptors with `F_NOCACHE`. Drive events: DiskArbitration. Connection path: IOKit. Volume actions: `/usr/sbin/diskutil` run as a child process.
- Not sandboxed. No network. No privileged helper. Reasons in Key decisions.
- Tests: unit tests in the package (framework chosen in M1). No CI yet.

## Verified platform facts

Checked on 2026-11-05 on this Mac. "Local test" means a research agent ran it here. Khan was only read, never written.

| Fact | Evidence |
| --- | --- |
| exFAT is mounted through `fskit` (user-space driver). Khan: exFAT, 128 KB clusters, 62.9 GB. | `mount`, `diskutil info` |
| `F_NOCACHE` does not purge pages already in the cache. It only stops new caching on that descriptor. | `man fcntl`, XNU `vfs_cluster.c`, local test |
| A plain write then an `F_NOCACHE` read returned stale cached data. With `F_NOCACHE` set on the writer before the first write, the read hit the device. | Local test on a RAM-disk exFAT volume |
| Cold `F_NOCACHE` reads on Khan ran at about 22 MB/s. Cached reads ran at about 10 GB/s. | Local test |
| Misaligned I/O silently falls back to the cached path. Page size is 16 KiB. | Local test, `hw.pagesize` |
| `F_FULLFSYNC` returns 0 on exFAT. Whether the drive controller flushes is not provable from user space. | Local test, `man fsync` |
| Bitcoin Core issue 31453 reports silent `F_FULLFSYNC` failure and corruption on exFAT around macOS 15.2. The driver may have changed since. | mirror.b10c.me/bitcoin-bitcoin/31453 |
| Unmount then mount drops the cache. Not yet tested on real USB. `purge` needs root. | Local test (RAM disk) |
| `/dev/rdisk9` is denied to the user. `F_LOG2PHYS_EXT` returns `ENOTSUP` on FSKit exFAT. | Local test |
| `diskutil eraseDisk ExFAT LABEL MBR diskN` worked without sudo on a RAM disk. Real USB nodes are `root:operator 0640`, so admin may be needed. Label max 11 characters. | Local test, exFAT spec |
| Removable and Ejectable are unreliable for USB SSDs. Disk images report protocol `Virtual Interface`. Boot volumes report `Apple Fabric`. | Local test, Apple Community, Chromium source |
| FAT32 max file size is 4 GiB minus 1 byte. NTFS is read-only in macOS. The MBR type `Windows_NTFS` also labels exFAT. | Microsoft docs, Eclectic Light |
| `ProcessInfo.beginActivity(.userInitiated)` blocks idle sleep and App Nap. Lid close can still sleep the Mac. | Local test (`pmset -g assertions`), `IOPMLib.h` |
| Unsigned rebuilds trigger repeated privacy prompts. Files picked in an open panel or dropped on the app need no prompt. | Apple docs, Apple Developer Forums |

## System diagram

```
+------------------------------ USBVerify.app ------------------------------+
|  SwiftUI views  <---- observes ----  AppModel (main actor)                |
|  Sidebar, Drive card, Review sheet,        |                              |
|  Jobs, History, Menu bar item              | commands / events            |
|                                            v                              |
|                          JobCoordinator (queue, one active job)           |
|                                            |                              |
+--------------------------------------------|------------------------------+
                                             v
+---------------------------- USBVerifyCore (package) ----------------------+
|  Preflight   Verifier   JobRunner (state machine)   JobStore   History    |
|  Chunking    Hashing    CapacityTest   DotCleanup    FormatPlan   RunLog  |
|                    |                         |                            |
|          DriveIO (protocol)        SystemPorts (protocols)                |
+--------------------|-------------------------|---------------------------+
                     v                         v
        PosixDriveIO | FakeDrive      DiskArbitration, IOKit, diskutil,
        (real fds)   (a folder)       notifications, power assertions
                                      (real adapters in the app target,
                                       fakes in tests)
```

## Processes

- One app process. It runs the UI on the main actor and each job on its own task.
- `diskutil` runs as a short-lived child process for unmount, mount, eject, and erase. A hung call times out and the job pauses.
- The menu bar item lives in the same process (`NSStatusItem`).
- No launch agents, no daemons, no helper tool.
- Restart policy: none. After a crash or quit, jobs come back as Paused from their state files.

## Modules and ownership

Other modules use only the listed API, never internals.

| Module | Owns | Exposes |
| --- | --- | --- |
| Chunking | chunk plan for a size, 16 KiB alignment rules | `ChunkPlan` |
| Hashing | streaming SHA-256, chunk hashes, whole-file hash | `Hasher` |
| DriveIO | open writer and reader descriptors with `F_NOCACHE`, aligned buffers, `fsync`, `F_FULLFSYNC`, read, write | `DriveIO` protocol, `PosixDriveIO`, `FakeDrive` |
| Verifier | per-chunk write and read-back, retry rule, byte-level diff, cache guard | `verifyChunk`, `BadRange` |
| Preflight | filesystem, read-only, free space, FAT32 limit, name rules, source-on-target check | `PreflightReport` |
| Volumes | volume model, listing filter, identity by volume UUID, destination guard | `VolumeCatalog`, `DestinationGuard` |
| JobRunner | job state machine, copy, final pass, resume | `JobRunner`, `JobEvent` |
| JobStore | atomic state files | `JobStore` |
| CapacityTest | seeded test data, manifest, fill and compare | `CapacityRunner` |
| DotCleanup | scan and delete `._` files inside one folder tree | `DotCleaner` |
| FormatPlan | command builder, confirmation rules, generic-name rule | `FormatPlan` |
| History, RunLog | JSONL history and text log writers, route grouping | `HistoryStore`, `RunLog` |
| SystemPorts | protocols for drive events, volume control, connection info, notifications, power | `VolumeEvents`, `VolumeControl`, `ConnectionInfo`, `Notifier`, `PowerGuard` |

The app target owns: SwiftUI views, `AppModel`, `JobCoordinator`, and the real adapters for the ports.

## Internal communication

- Views read `AppModel`. `AppModel` calls `JobCoordinator`. The coordinator starts a `JobRunner` and receives `JobEvent` values over an `AsyncStream`.
- Drive events arrive from DiskArbitration callbacks through `VolumeEvents`. The coordinator pauses the matching job on removal.
- I/O errors: a failed read or write is retried by the Verifier under the 3-retry rule. `EIO`, `ENXIO`, or a timeout on a vanished device is treated as a disconnect, not a chunk failure.
- Every `diskutil` call has a timeout. Failure becomes a typed error with the command output.
- No shared mutable state across jobs. The coordinator runs one job at a time.

## Key flows

**Copy (Strict)**
1. Review sheet passes. Preflight runs. Any refusal stops the job with zero writes.
2. The coordinator starts power assertion and creates the state file.
3. For each file: create the temp file. Run the chunk loop (spec section 8).
4. Final pass: source check, unmount, mount, find the volume again by UUID (the mount path can change), re-read, compare, whole-file hash.
5. On PASS: rename the temp file, delete the state file, write history and log, notify, offer Eject.

Failure paths and what the user sees:
- Chunk fails 3 times: job stops, file renamed `.FAILED-partial`, result FAIL with ranges, button Keep scanning.
- Drive vanishes: job and batch go to Paused, message "Drive disconnected at X of Y. Reconnect to resume."
- Unmount busy: phase shows "Waiting for unmount", names the blocking process if `diskutil` reports one, button Retry. No PASS.
- Source changed: FAIL "source changed during copy".
- Wake from sleep: Paused, same as a disconnect, because USB power may have dropped.

**Resume**
1. Same volume UUID returns. Notification. Blair presses Resume.
2. Check the source (size, modified time, inode). A change restarts the file from 0.
3. Re-read the last 4 chunks of the temp file. Step back on a failure.
4. Continue the chunk loop from the last good chunk.

**Verify-only**
1. Match source files to files in the chosen drive folder by name.
2. Unmount and mount. Re-read each file by chunk. Hash the source in the same loop.
3. Compare, report ranges, write history. No writes to the drive.

Format, capacity test, and `._` cleanup follow the steps in `spec.md` sections 12 to 14.

## State machines

**Job**

| State | Event | Next state | Side effect |
| --- | --- | --- | --- |
| Queued | start | Preflight | none |
| Preflight | refused | Failed | no write, error shown |
| Preflight | ok | Copying | state file created, power assertion on |
| Copying | chunk verified | Copying | chunk hash saved |
| Copying | 3 retries failed | Failed | rename to `.FAILED-partial`, Keep scanning offered |
| Copying | last chunk done | Finalizing | close descriptors |
| Finalizing | source changed | Failed | FAIL "source changed" |
| Finalizing | unmount busy | WaitingUnmount | Retry offered |
| WaitingUnmount | retry ok | Finalizing | mount again |
| Finalizing | final pass ok | Passed | rename, history, notify |
| Finalizing | final pass mismatch | Failed | ranges reported |
| any running | disconnect, wake, quit | Paused | state file kept |
| Paused | Resume, volume UUID matches | Copying | tail chunks re-checked |
| any | Cancel | Cancelled | ask to delete partial file |

Passed, Failed, and Cancelled are final. A resumed job continues the same job id.

## Data model

Types are defined once in `USBVerifyCore/Sources/USBVerifyCore/Jobs/` and `.../Volumes/`. Shown here: entities and rules.

- **Volume**: volume UUID (identity), name, size, free space, filesystem kind, read-only flag, whole-disk BSD id, model, protocol, route.
- **Route**: protocol, hub in path (yes or no), hub depth, negotiated speed, port location. {{TODO: confirm IOKit property names in spike S3}}
- **Job**: id, kind (copy, verify-only, capacity, format), mode, volume UUID, destination folder, file list, per-file state, phase.
- **FileJob**: source path, size, modified time, inode, temp name, final name, chunk size, chunk hashes, last verified offset, retries, warnings.
- **BadRange**: byte offset and length in the file.
- **RunRecord**: one history line (spec section 17).

Rules: times are UTC in files and shown local (EAT) in the UI. Sizes are bytes. Offsets are bytes from the file start. A volume is never identified by name or BSD id after the first listing.

## Files on disk

| Path | Contents | Writer | Backup |
| --- | --- | --- | --- |
| `~/Library/Application Support/USBVerify/jobs/<id>.json` | job state | JobStore, atomic write after each verified chunk | none, deleted after PASS |
| `~/Library/Application Support/USBVerify/history.jsonl` | one record per run | HistoryStore, append | none |
| `~/Library/Logs/USBVerify/usb-verify.log` | text log | RunLog, append | none |
| `<drive>/<folder>/<name>.usbverify-part` | file being copied | Verifier | none |
| `<drive>/usbverify-test-NNNN.bin` | capacity test data | CapacityRunner | none, always deleted |

## Security model

- Trust boundary: the app only writes to the chosen volume. `DestinationGuard` checks the volume UUID and the resolved real path (no symlink escape) before every write.
- Internal disks, the boot volume, disk images, and network volumes never reach the guard as targets.
- Erase uses the BSD id re-resolved from the volume UUID right before the command. It is blocked while the drive has a job.
- Only three paths delete data: Format, `._` cleanup, and capacity test cleanup. Each needs a confirmation. Cleanup deletes only listed `._` files and tracked test files.
- Admin rights appear only in the Format fallback, through the standard macOS prompt. The app never stores a password.
- The admin fallback runs `diskutil` as root with a label Blair types. Only whitelisted label characters (letters, digits, space, hyphen, underscore) and a BSD id matching `^disk[0-9]+$` may reach it. Arguments go as an array. If the prompt needs a shell string, every value is shell-quoted. `FormatPlan` owns this check.
- No secrets, no network. Logs and history never hold file contents.
- Privacy: user-picked and dropped files need no prompt. Writes to a removable volume may prompt once. A stable signing certificate stops repeat prompts.

## Performance budgets

| Path | Metric | Budget | How measured |
| --- | --- | --- | --- |
| Drive list | plug-in to visible | 2 s | spike S2, then manual |
| Progress UI | update interval | at most 1 s | fake drive with throttle |
| Quick mode, 30 GB | total time | about 2 times the write time | M5 real hardware |
| Strict mode, 30 GB | total time | about 3 times the write time | M5 real hardware |
| Memory per job | buffers | two 64 MiB buffers, under 300 MB resident | Instruments, M2 |
| Cache guard | read-back speed flag | above 1 GB/s (tune in S1) | spike S1 |

## Key decisions and trade-offs

| Decision | Options | Choice | Given up |
| --- | --- | --- | --- |
| How to defeat caches | `F_NOCACHE` only, remount, raw device | `F_NOCACHE` on both descriptors plus remount | Raw device would be strongest but is denied to the user and needs a helper |
| Drive-internal cache | replug prompt, ignore | ignore in v1 | A tiny file can be served from the drive cache. Large files evict it |
| Final hash | re-hash source, hash while chunking | hash while chunking | none, source is read once |
| Failure policy | stop, continue, ask | stop, Keep scanning button | Full damage map costs one more click |
| Final name | write in place, temp then rename | temp then rename | Needs a rename after the final pass |
| Format rights | helper, admin prompt, Disk Utility | admin prompt fallback | A helper would be smoother but adds a permanent privileged tool |
| Filesystems | all, exFAT and FAT32 | exFAT and FAT32 | APFS and HFS+ targets |
| Drive filter | removable flag, USB only, all external | all external | A few more volumes to look at |
| Testing | real drive now, simulate | simulate first | Real behavior is unproven until M5 |

## Automated quality checks

Planned. None exist yet.

- `swift test --package-path USBVerifyCore` runs the core unit tests. A failing test fails the build.
- `xcodebuild -scheme USBVerify build` builds the app. Warnings are reviewed before M2 closes.
- Fake-drive tests cover acceptance items 1 to 17. The RAM-disk harness script covers the FSKit cache and remount behavior.
- {{TODO: choose the test framework and the lint tool in M1}}
