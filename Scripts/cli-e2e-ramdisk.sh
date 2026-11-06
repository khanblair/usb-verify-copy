#!/bin/zsh
#
# End-to-end check of the usbverify command line tool on a RAM disk.
# It makes a 128 MB exFAT RAM disk (never a real drive), copies and verifies files with
# the real engine, damages one byte on the RAM disk's raw device, expects verify to catch it,
# and tests Ctrl+C pause and resume. The RAM disk is always removed at the end.
#
# Usage: Scripts/cli-e2e-ramdisk.sh        (run from the repo root; builds the release binary first)

set -u
root="${0:A:h:h}"
cli="$root/USBVerifyCore/.build/release/usbverify"
work="$(mktemp -d)"
pass=0
fail=0
name="USBVTEST"

check() {  # check <description> <condition-exit-code>
  if [[ "$2" == "0" ]]; then print "  ok   $1"; pass=$((pass + 1)); else print "  FAIL $1"; fail=$((fail + 1)); fi
}

cleanup() {
  "$root/Scripts/ramdisk-exfat.sh" remove >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

[[ -x "$cli" ]] || { print "Build first: cd USBVerifyCore && swift build -c release"; exit 2; }

print "== make RAM disk"
out=$("$root/Scripts/ramdisk-exfat.sh" create 128 "$name" 2>/dev/null) || { print "could not make the RAM disk"; exit 2; }
device=$(print -r -- "$out" | sed -n 's/^DEVICE=//p')
mount_path=$(print -r -- "$out" | sed -n 's/^MOUNT=//p')
print "  $device at $mount_path"

# Safety: raw writes only ever go to a virtual disk image.
info=$(diskutil info -plist "$device" | plutil -p - 2>/dev/null)
print -r -- "$info" | grep -q '"BusProtocol" => "Disk Image"' || { print "not a disk image, stopping"; exit 2; }
print -r -- "$info" | grep -q '"Internal" => false' || { print "unexpected internal flag, stopping"; exit 2; }

dd if=/dev/urandom of="$work/src.bin" bs=1048576 count=24 2>/dev/null
src_hash=$(shasum -a 256 "$work/src.bin" | cut -d' ' -f1)

print "== list"
"$cli" list --include-disk-images < /dev/null | grep -q "$name"
check "list shows the RAM disk" $?
"$cli" list < /dev/null | grep -q "$name"
check "list hides it without --include-disk-images" $((! $?))

print "== dry run writes nothing"
"$cli" copy --drive "$name" --include-disk-images --to demo --dry-run --yes "$work/src.bin" < /dev/null > "$work/dry.txt" 2>&1
check "dry run exits 0" $?
[[ ! -e "$mount_path/demo/src.bin" ]]
check "dry run created no file" $?

print "== strict copy"
"$cli" copy --drive "$name" --include-disk-images --to demo --yes "$work/src.bin" < /dev/null > "$work/copy.txt" 2>&1
code=$?
check "copy exits 0 (got $code)" $code
grep -q "PASS" "$work/copy.txt"
check "output says PASS" $?
grep -q "matches the source" "$work/copy.txt"
check "output says the file matches the source" $?
mount_path=$(diskutil info -plist "$device" | plutil -extract MountPoint raw -o - - 2>/dev/null)
[[ "$(shasum -a 256 "$mount_path/demo/src.bin" | cut -d' ' -f1)" == "$src_hash" ]]
check "file on the drive has the same SHA-256 as the source" $?
[[ -z "$(ls "$mount_path/demo" | grep 'usbverify-part')" ]]
check "no .usbverify-part file left" $?

print "== verify only passes on a good file"
"$cli" verify --drive "$name" --include-disk-images --folder demo "$work/src.bin" < /dev/null > "$work/verify1.txt" 2>&1
check "verify exits 0" $?

print "== damage one byte behind the filesystem, verify must FAIL"
python3 - "$device" "$work/src.bin" <<'PY'
import os, sys
device, src = sys.argv[1], sys.argv[2]
raw = "/dev/r" + device[len("/dev/"):]
pattern_offset = 8 * 1024 * 1024
with open(src, "rb") as f:
    f.seek(pattern_offset)
    pattern = f.read(4096)
fd = os.open(raw, os.O_RDWR)
size = 128 * 1024 * 1024
pos = 0
while pos + 4096 <= size:
    block = os.pread(fd, 4096, pos)
    if block == pattern:
        damaged = bytearray(block)
        damaged[0] ^= 1
        os.pwrite(fd, bytes(damaged), pos)
        print("flipped one byte at device offset", pos)
        sys.exit(0)
    pos += 4096
print("pattern not found")
sys.exit(1)
PY
check "found and flipped a byte on the raw device" $?
"$cli" verify --drive "$name" --include-disk-images --folder demo "$work/src.bin" < /dev/null > "$work/verify2.txt" 2>&1
code=$?
check "verify exits 1 after damage (got $code)" $((code != 1))
grep -qi "0x800000" "$work/verify2.txt"
check "verify reports the exact offset 0x800000" $?
grep -q "does NOT match" "$work/verify2.txt"
check "output says the file does NOT match" $?

print "== Ctrl+C pauses and resume finishes"
dd if=/dev/urandom of="$work/big.bin" bs=1048576 count=80 2>/dev/null
"$cli" copy --drive "$name" --include-disk-images --to demo --yes "$work/big.bin" < /dev/null > "$work/big1.txt" 2>&1 &
pid=$!
# Send Ctrl+C as soon as the copy is really running, not after a fixed delay.
started=0
for i in {1..300}; do
  if grep -q "copying" "$work/big1.txt" 2>/dev/null; then started=1; break; fi
  sleep 0.1
done
check "copy started" $((started != 1))
sleep 1
kill -INT $pid 2>/dev/null
wait $pid
code=$?
check "Ctrl+C exits 3 (got $code)" $((code != 3))
grep -q "Resume with: usbverify resume" "$work/big1.txt"
check "prints how to resume" $?
job=$(sed -n 's/.*usbverify resume \([A-Za-z0-9-]*\).*/\1/p' "$work/big1.txt" | head -1)
[[ -n "$job" ]]
check "found a job id" $?
"$cli" jobs --include-disk-images < /dev/null | grep -q "${job:-NOJOB}"
check "jobs lists the paused job" $?
"$cli" resume "${job:-NOJOB}" --include-disk-images < /dev/null > "$work/big2.txt" 2>&1
check "resume exits 0" $?
mount_path=$(diskutil info -plist "$device" | plutil -extract MountPoint raw -o - - 2>/dev/null)
[[ "$(shasum -a 256 "$mount_path/demo/big.bin" | cut -d' ' -f1)" == "$(shasum -a 256 "$work/big.bin" | cut -d' ' -f1)" ]]
check "resumed file has the same SHA-256 as the source" $?

print ""
print "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]]
