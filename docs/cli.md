# usbverify command line tool

Build the tool with:

```sh
cd USBVerifyCore
swift build -c release
```

The binary is at `.build/release/usbverify`.

## Commands

```text
usbverify list [--include-disk-images]
usbverify copy --drive <name|uuid|number> --to <folder> [--mode strict|quick] [--on-conflict ask|replace|skip|keep-both] [--dot-clean] [--dry-run] [--yes] <file>...
usbverify verify --drive <name|uuid|number> --folder <folder> <source file>...
usbverify resume <job-id>
usbverify jobs
usbverify eject --drive <name|uuid|number>
usbverify help
```

Examples:

```sh
usbverify list
usbverify copy --drive BACKUP --to Packages --mode strict --yes game.pkg
usbverify verify --drive BACKUP --folder Packages game.pkg
usbverify resume 7A3D...
```

`copy` accepts files only. The destination is always a folder below the chosen drive root. Strict mode is the default. A dry run prints the plan and writes nothing. Existing names need an explicit conflict policy. `--yes` confirms the copy and cleanup prompts, but never skips preflight or chooses a conflict policy.

Exit codes are 0 for all PASS results, 1 when a file FAILs, 2 for usage or preflight errors, 3 for a paused job, and 4 for an internal error.

Only catalog volumes are accepted. Copy targets must be exFAT or FAT32 and writable. The tool uses the volume UUID, checks every destination path, writes a temporary name, and renames it only after the final verification. It does not format drives or run capacity tests. `._` files are listed and deleted only with `--dot-clean` after a passing run and confirmation.
