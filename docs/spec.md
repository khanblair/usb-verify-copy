# USB Verify Copy: Spec

Status: aligned with Blair on 2026-11-05. Replaces draft 1. Open items are in `progress-tracker.md`.

## 1. Problem

Large files (5 to 30 GB, such as PS4 `.pkg` files) copied from a MacBook Air to a USB drive sometimes arrive corrupted. The copy ends without an error and the checksum differs from the source. Today the only check is to hash the whole file afterwards. That takes 10 to 15 minutes per file and does not say where the damage is.

The corruption has been seen through a hub or adapter. The cause is not proven. Suspects: the hub or adapter, the drive itself (failing, or fake capacity), and the new FSKit exFAT driver in macOS. The app is a detector. If the drive or the path is bad, the right output is FAIL with the bad byte ranges. It cannot repair a bad drive.

## 2. Goal

A native macOS app that copies files to a USB drive and proves the copy is correct. It verifies chunks while writing, then remounts the drive and re-reads everything, so it is not fooled by caches. It shows which byte ranges are bad, retries them, and says plainly whether the file on the drive matches the source. It also shows how the drive is connected, so a bad hub or adapter shows up in the history.

## 3. Platform

- One user: Blair. MacBook Air (M3, Apple silicon), macOS 27.2.
- Deployment target: macOS 27.2. Swift 6.4, SwiftUI, Xcode 27.0.
- Not sandboxed. Not notarized. Signed with a personal Apple Development certificate, so macOS privacy approvals survive rebuilds.
- Runs as a normal `.app`.

## 4. Locked decisions

| ID | Decision | Reason |
| --- | --- | --- |
| D1 | Two modes: Strict (default) and Quick. The remount re-read is mandatory in both. PASS never shows before it. | A read-back right after a write can come from a cache. A fake-capacity drive also passes it. |
| D2 | A chunk that still fails after 3 retries stops the file: result FAIL, file renamed `name.FAILED-partial`, button "Keep scanning". The batch moves on. | A `.pkg` with one bad range is useless. A failing drive wastes time. |
| D3 | v1 has: copy, verify-only, format, capacity test, `._` cleanup, history by route, menu bar status. | Blair's choice. |
| D4 | Files only. Folders come in v1.1. | Folders add symlinks, hidden files, nested state. |
| D5 | Write to `name.usbverify-part`. Rename only after PASS. If the final name exists, ask per file. | A half-written file under its real name looks valid. |
| D6 | Sidebar layout: Drives, Jobs, History, plus a detail pane. | Paused jobs and history need a home. |
| D7 | Normal window plus menu bar status. Block idle sleep during a job. Notify on PASS, FAIL, pause. | Jobs run 30+ minutes. |
| D8 | Format guard: show name, size, BSD id, model, all partitions. Type the BSD id, or the name if it is not generic. | A typed name alone is weak. |
| D9 | Format tries plain `diskutil`. On a permission refusal it retries through the macOS admin password prompt. No helper tool. | Admin need on real USB is unverified. |
| D10 | Capacity test has two modes: free space only (default) and whole drive (erase first). | A conclusive test must fill the free space. |
| D11 | Resume is manual: a Resume button after a "drive is back" notification. | Blair may unplug on purpose. |
| D12 | List every volume that is not internal, not the boot volume, not a disk image, not a network volume. | USB SSDs report not removable. |
| D13 | Copy targets: exFAT and FAT32 only. Other filesystems show greyed out. | The cache-bypass guarantee is proven on exFAT first. |
| D14 | If unmount is busy: show who blocks it, offer Retry, never force. No PASS until the remount works. | Keeps D1 true. |
| D15 | Connection awareness: path and speed on the drive card, logged each run, hub warning, history by route. | The hub is the main suspect. |
| D16 | No raw device reads. No privileged helper. | Raw device is denied to the user, and `F_LOG2PHYS_EXT` is not supported on FSKit exFAT. |
| D17 | Simulate everything first. Real-drive tests come later (M5). | Blair chose this. Khan holds Blair's data, so no destructive test touches it. |
| D18 | Build order: risk spikes, core engine, app shell, extras, real-hardware proof. | The biggest risks are platform behavior. |

Defaults not yet confirmed by Blair as separate questions: 64 MiB chunk, 3 retries, SHA-256, one active job at a time (others queue), a review sheet before each start.

## 5. Scope

**In v1**
- Detect drives on plug-in and removal. Show connection path and speed.
- Copy one or more files to a folder on the drive, in Strict or Quick mode.
- Verify-only: check files already on the drive against the source.
- Format a drive as exFAT with an MBR partition table.
- Capacity test (free space only, or whole drive).
- Optional `._` cleanup in the job's destination folder.
- Pause on disconnect, sleep, or quit. Manual resume.
- Run history and a plain-text log. Per-route PASS and FAIL counts.

**Out of scope**
- App Store or notarized distribution.
- Copying from the drive to the Mac.
- Folder copies (v1.1).
- Copying extended attributes or resource forks. The app writes bytes only.
- Making a drive bootable or writing PS4 folders.
- Repairing a drive or filesystem.
- Checking what a `.pkg` does. The tool proves bytes match, not that a package installs.
- Raw device access and privileged helpers.

## 6. Screens and flow

**Sidebar.** Drives, Jobs (running and paused), History. A menu bar item shows job status when the window is closed.

**Drives.** One card per physical drive, with its volumes listed under it. Each card shows: name, size, filesystem, free space, connection (see section 15). Actions: Copy, Verify-only, Format, Capacity test. Dragging files from Finder onto a drive card starts a copy.

**Copy flow.**
1. Pick or drop source files, then pick a destination folder on that drive.
2. Review sheet: files, drive and folder, mode, free-space check, any name conflicts, time estimate, optional `._` cleanup checkbox. Button: Start.
3. Progress. Per file: phase, percent, MB/s, chunks verified, chunks retried, time left. Also batch totals. Phases: Copying, Reading back, Unmounting, Remounting, Final check, Renaming. The display updates at least once per second.
4. Result. Per file: PASS, or FAIL with the bad byte ranges (offset and length, in hex and bytes). A line says plainly whether the file on the drive matches the source. Buttons: Eject, Show log. After a FAIL behind a hub, the sheet suggests a re-test on a direct port.
5. Every run writes history and log entries.

**Jobs.** Lists running, queued, and paused jobs. Paused jobs survive an app relaunch. Resume and Cancel live here.

**History.** Past runs with filters. A route view shows PASS and FAIL counts per connection route, such as "via hub: 3 of 5 failed".

**Notifications.** PASS, FAIL, paused (disconnect or wake), and "drive is back".

**Errors.** Every error shows plain English first and the technical detail in an expander. PASS, FAIL, and paused use an icon and a label, never colour alone.

## 7. Drive rules

- A volume is listed when: Internal is false, it is not the boot volume, not a disk image, not a network volume.
- A volume with Time Machine backups gets a badge and an extra confirm before Format.
- Copy needs: filesystem exFAT or FAT32 (from the volume kind, not the partition type), and the volume is not read-only (check the mount flags).
- Refuse before any write when: unsupported filesystem, read-only volume, a file is 4 GiB or bigger on FAT32, free space is smaller than the batch size, a file name breaks exFAT or FAT32 rules (offer a rename), or a source file lives on the destination drive.
- A drive is identified by its volume UUID. Never by name or by `disk9`.
- The app never writes to the internal disk or to a drive other than the chosen one. A destination guard checks the volume UUID and the resolved path before every write.
- Copy never deletes. Only Format, `._` cleanup, and the capacity test's own cleanup remove data, and each one asks first.
- Backup warning: on a fake-capacity drive, test writes can overwrite existing files. Format and the capacity test warn about this.

## 8. Verification method

**Chunk size:** 64 MiB. **Retries:** 3. **Hash:** SHA-256. All buffers and offsets are multiples of 16 KiB.

**Per chunk (Strict):**
1. Read the chunk from the source. Add it to the running source hash. Compute its chunk hash.
2. Write it to the temp file at the same offset, through a writer file descriptor that has `F_NOCACHE` set right after open. Then `fsync` and `F_FULLFSYNC`. A failed `F_FULLFSYNC` is a logged warning.
3. Read the range back through a separate reader file descriptor with `F_NOCACHE`. Compare it byte for byte with the source chunk and check its hash.
4. On a mismatch, rewrite and re-check, up to 3 times. After the third failure, apply D2.
5. Save the chunk hash in the job state.

**Quick** skips step 3. A bad chunk is found in the final pass.

**Final pass (both modes):**
1. Check the source size and modified time are unchanged. A change means FAIL "source changed during copy".
2. Close the file. Unmount the volume, then mount it again. If unmount is busy, apply D14. After the remount, find the volume again by its volume UUID, because the mount path can change (for example `/Volumes/Khan 1`).
3. Re-read the whole temp file with `F_NOCACHE`. Compare each chunk hash with the stored one. Compute the whole-file hash from that re-read.
4. On a chunk mismatch, re-read the source chunk and report the exact differing byte ranges.
5. Rename the temp file to its final name only on PASS.

**Result rules**
- PASS: every chunk hash matches in the final pass, and the whole-file hash from the re-read equals the source hash from the first read.
- FAIL: any chunk failed after retries, any final-pass mismatch, or a source change.

**Cache guard.** If a read-back runs far above the drive's physical speed, flag "read came from cache, not trusted". Default threshold 1 GB/s. {{TODO: tune the threshold in spike S1 from measured drive speeds}}

**Time cost.** Quick is about 2 times the write time. Strict is about 3 times. For a 30 GB file, with writes at 20 to 30 MB/s and the measured cold read of 22 MB/s on Khan, Quick takes roughly 40 to 50 minutes and Strict roughly 60 to 75 minutes.

## 9. Destination files

- Here `name` means the full file name with its extension, so `game.pkg` uses the temp name `game.pkg.usbverify-part`. A failed or cancelled file becomes `game.pkg.FAILED-partial`, or is deleted if Blair chooses.
- If the final name exists, ask per file: replace, skip, or keep both. If the existing file already matches the source hash, offer "skip, already verified". Never overwrite silently.
- Cancel asks whether to delete the partial file.

## 10. Pause and resume

- State file per job: `~/Library/Application Support/USBVerify/jobs/<job-id>.json`, written atomically after each verified chunk.
- It stores: volume UUID, destination folder, temp and final names, source path, size, modified time, inode, mode, chunk size, verified chunk hashes, last verified offset, phase.
- A disconnect, a wake from sleep, or a quit pauses the whole batch. The app shows "Drive disconnected at X of Y. Reconnect to resume."
- When the same volume UUID returns, the app notifies Blair. Resume is a button.
- On resume: check the source is unchanged (size, modified time, inode). If it changed, restart that file from 0. Then re-read the last 4 chunks of the temp file. If any fails, step back one chunk at a time to the last good one. The final pass verifies everything anyway.
- The state file is deleted after PASS. History stays.

## 11. Verify-only

Read-only on the drive. Blair picks source files and a drive folder. The app matches files by name and shows unmatched ones. It remounts first, then runs the final pass. Result per file: PASS or FAIL with bad ranges. It writes history like a copy.

## 12. Format

- Command: `diskutil eraseDisk ExFAT <LABEL> MBR <diskN>`. The label is at most 11 characters.
- Confirmation sheet: name, size, BSD id, model, and every partition that will be wiped. Type the BSD id, or the drive name if it is not generic (generic means empty, "Untitled", "NO NAME", or shared by two volumes).
- Right before the erase, re-resolve the volume UUID and check it still matches. Block Format when the drive has a running or paused job.
- Try plain `diskutil` first. On a permission refusal, retry through the macOS admin password prompt (D9). On any failure, show the `diskutil` output.
- Input safety, because the admin retry runs `diskutil` as root. The label may use only letters, digits, space, hyphen, and underscore. The BSD id must match `^disk[0-9]+$`. Pass arguments as an array. If a shell string is unavoidable for the admin prompt, shell-quote every value.

## 13. Capacity test

- Free space only (default): write 1 GB test files of seeded pseudo-random data into the free space, remount, read them back, compare, delete them. Existing files are not touched or checked. If the drive is nearly full, the test covers only the free part and says so.
- Whole drive: Format first (full Format confirmation), then the same fill and read-back.
- Test files are named `usbverify-test-NNNN.bin` and tracked in the job state. Only those files are ever deleted.
- Resumable and cancellable. Cleanup always runs. Expect about an hour per 32 GB.
- Report: tested size, good files, bad files with ranges, and a clear "looks genuine" or "looks fake or failing".

## 14. `._` cleanup

- Checkbox on the review sheet: "Remove macOS ._ files after copying". Off by default.
- Scope: the job's destination folder and its subfolders. Runs only after PASS. Lists the files first and asks for confirmation.
- The app never copies extended attributes, so its own copies create no `._` files. This cleans up older ones.

## 15. Connection awareness

- Drive card shows: bus or protocol, port type, whether a hub or adapter is in the path, and the negotiated speed (USB 2 or USB 3).
- Warn when a drive runs at USB 2 speed, because a 30 GB copy then takes much longer.
- Hub warning banner: "This drive sits behind a hub or adapter." After a FAIL, suggest a direct-port re-test.
- Every run logs the route, the filesystem driver (`fskit` or kext), and the macOS version.
- History groups runs by route. {{TODO: confirm the IOKit properties for hub depth and speed in spike S3}}

## 16. Errors

Each shows plain English plus technical detail: drive removed or woke from sleep, not enough free space, unsupported filesystem, read-only volume, file too large for FAT32, bad file name, permission denied, source changed during copy, unmount busy (with who blocks it), chunk failed after 3 retries (with offset), final pass mismatch, read-back not trusted (cache guard), format failed (with `diskutil` output).

## 17. Logs and history

- Text log: `~/Library/Logs/USBVerify/usb-verify.log`. For humans.
- History: `~/Library/Application Support/USBVerify/history.jsonl`. One record per run, used by the History view.
- Each record: start and end time, mode, drive name, volume UUID, model, filesystem and driver, macOS version, connection route, source and destination paths, sizes, chunk size, retries, bad ranges, `F_FULLFSYNC` warnings, source hash, re-read hash, result.
- Neither file ever holds file contents.

## 18. Acceptance criteria

Items 1 to 17 are proven first against the fake drive (section 19). Item 18, and a re-run of everything on real hardware, is milestone M5.

1. A plugged-in external drive appears within 2 seconds. Unplugging removes it. Internal disks, the boot volume, disk images, and network volumes never appear.
2. Unsupported filesystem, read-only volume, FAT32 file over the limit, too little free space, bad name, or source on the target drive: refused before any write. Zero bytes written.
3. During a 15 GB copy, progress updates at least once per second.
4. A test hook that flips one byte on write is detected in Strict, retried, and reported with its offset. After 3 failures the job stops with FAIL and the file is renamed `.FAILED-partial`.
5. A test hook that corrupts data after the read-back passes (like wrap-around) is caught by the final pass and reported with exact ranges. PASS never shows before the final pass.
6. A passing copy reports PASS. The log shows the source hash equal to the re-read hash.
7. Quick mode finds a bad chunk in the final pass and reports the offset.
8. A disconnect mid-copy pauses the batch and shows the offset. Reconnecting the same volume UUID and pressing Resume finishes the file with matching hashes. A changed source restarts that file from 0.
9. A wake from sleep pauses the job like a disconnect.
10. An existing final name triggers the per-file question. Nothing is overwritten silently. A temp file is renamed only after PASS.
11. Format is refused without the typed BSD id (or name), is blocked during a job, and re-checks the volume UUID right before the erase. Labels over 11 characters are refused.
12. The capacity test detects a simulated wrap-around, deletes all its test files, and touches no other file.
13. `._` cleanup deletes nothing unless the checkbox is on and the listed files were confirmed. It never leaves the destination folder.
14. The destination guard blocks any write to the internal disk or to a drive other than the chosen one.
15. A read-back far above the drive's speed raises the cache guard warning.
16. The menu bar item shows job status. Notifications fire on PASS, FAIL, and pause. While a job runs, the Mac's idle sleep is blocked (`pmset -g assertions` shows it).
17. Verify-only never writes to the drive. It finds a simulated bad range and reports its offset.
18. (M5, real hardware) The drive card shows protocol, hub, and negotiated speed. Each run logs the route. History shows PASS and FAIL counts per route.

## 19. Build and test plan

- Pure logic lives in the Swift package `USBVerifyCore` with unit tests. See `architecture.md` and `project-structure.md`.
- Fake drive: a folder on the internal disk behind the same I/O interface. Fault hooks: flip a byte on write, return stale data on read, corrupt after write, disconnect at an offset, throttle speed, fail `F_FULLFSYNC`, report no space, report busy unmount.
- Fake system adapters for drive events, `diskutil`, and notifications.
- A RAM-disk exFAT volume (same FSKit driver, no USB) tests cache bypass, remount, and erase behavior. No destructive test touches Khan or any drive with data.
- Before saying done: run the tests and the app, then check each acceptance item and report the real output.

## 20. Open items

Owned by `progress-tracker.md`: cache guard threshold, IOKit property names, number of tail chunks on resume, test framework choice, real-hardware proof of Format rights and remount on USB.
