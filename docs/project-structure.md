# Project structure

Where each file lives and what it is for. No code exists yet, so everything below is `(planned)`. How the parts work is in `architecture.md`.

## Rules for keeping this true

1. Update this file in the same change that adds, moves, or deletes a file.
2. Every listed file or folder has a one-line purpose.
3. Planned files carry `(planned)`. Remove the tag when the file exists.
4. If this tree and the disk disagree, the disk wins. Fix this file.

## Root

```
usb-tool/
  README.md                  doc map and reading order
  docs/                      project docs (below)
  USBVerifyCore/             Swift package: all logic without UI (planned)
  USBVerify/                 Xcode app project (planned)
  Scripts/                   helper scripts (planned)
  .gitignore                 build output and Xcode user data (planned)
```

There is no git repository yet. Run `git init` when code starts, and use the SSH alias `github-personal` for the remote.

## docs/

```
docs/
  spec.md                    product behavior, locked decisions, acceptance criteria
  architecture.md            stack, modules, flows, state machine, data, security
  project-structure.md       this file
  progress-tracker.md        status, tasks, decisions log, open questions
```

Only these four plus the root `README.md` exist on purpose. Other docs from the full set (build plan, code standards, UI tokens) are skipped. Their content lives in `spec.md`, `architecture.md`, and the tracker.

## USBVerifyCore/ (planned)

```
USBVerifyCore/
  Package.swift
  Sources/USBVerifyCore/
    Chunking/                chunk plan, 16 KiB alignment
    Hashing/                 streaming SHA-256, chunk and file hashes
    IO/                      DriveIO protocol, PosixDriveIO (F_NOCACHE, fsync)
    Verify/                  per-chunk verify, retry rule, byte diff, cache guard
    Preflight/               filesystem, space, FAT32 limit, name rules, source checks
    Volumes/                 Volume model, listing filter, DestinationGuard
    Jobs/                    JobRunner state machine, JobStore, Job and FileJob types
    Capacity/                seeded test data, manifest, fill and compare
    Cleanup/                 `._` scan and delete
    Format/                  FormatPlan, confirmation rules
    Logging/                 RunLog, HistoryStore, route grouping
    Ports/                   protocols for drive events, volume control, connection info, notifications, power
  Tests/USBVerifyCoreTests/
    Fakes/                   FakeDrive (a folder) with fault hooks, fake ports
    ...                      one test file per source folder
```

## USBVerify/ (planned)

```
USBVerify/
  USBVerify.xcodeproj        Xcode project. Generated and edited by Xcode.
  USBVerify/
    App/                     app entry point, window, menu bar item
    Model/                   AppModel, JobCoordinator
    Views/                   SwiftUI views: Sidebar, DriveCard, ReviewSheet, Jobs, History, Results
    System/                  real adapters: DiskArbitration, IOKit, diskutil runner, notifications, power
    Resources/               Info.plist, entitlements, assets
  USBVerifyUITests/          UI smoke tests, only if needed (planned)
```

## Scripts/ (planned)

```
Scripts/
  ramdisk-exfat.sh           make and remove a RAM-disk exFAT volume for cache and remount tests
```

## Generated files

| Path | Tool and command | Committed | Edit by hand |
| --- | --- | --- | --- |
| `USBVerify/USBVerify.xcodeproj/project.pbxproj` | Xcode | yes | no |
| `USBVerifyCore/.build/` | `swift build` | no | no |
| `DerivedData/` | Xcode | no | no |

## Where tests go

- Unit tests: `USBVerifyCore/Tests/USBVerifyCoreTests/`, one test file per source folder.
- Fakes and fault hooks: `USBVerifyCore/Tests/USBVerifyCoreTests/Fakes/`.
- Integration tests on a RAM-disk volume: `USBVerifyCore/Tests/USBVerifyCoreTests/RamDisk/`. They are skipped when the RAM disk is missing.
- Real-drive checks are manual. The checklist lives in `progress-tracker.md` under milestone M5.

## Naming rules

- Swift types and files: UpperCamelCase, one main type per file. Example: `JobRunner.swift`.
- Folders: UpperCamelCase nouns. Example: `Preflight/`.
- Protocols for ports end in the capability: `VolumeEvents`, `PowerGuard`.
- Test files end in `Tests`. Example: `VerifierTests.swift`.

## Shared and special files

- `Package.swift`: the only place that lists core targets and dependencies.
- `Resources/Info.plist` and entitlements: privacy usage strings, signing setup.
- App Support folder `~/Library/Application Support/USBVerify/`: runtime files, listed in `architecture.md`.
