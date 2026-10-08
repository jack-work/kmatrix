#!/usr/bin/env bash
# Runs the generated provisioner against the fake homeserver, while a watcher
# reads /proc/<pid>/cmdline of every descendant. Asserts the protocol still
# works AND that no secret was ever on a command line.
set -euo pipefail

PROVISION="$1"
PY="$2"
HERE="$3"
STATE="$4"

export HOME=$PWD
root=$PWD/rig
mkdir -p "$root"
export TMPDIR="$root/tmp"
mkdir -p "$TMPDIR"

# stand up the state directory the shipped provisioner was built against
rm -rf "$STATE"
install -d -m 0700 "$STATE" "$STATE/accounts"
printf 'TOPSECRETsharedregistrationsecretAAAA\n' > "$STATE/registration_shared_secret"
# a passwordFile with a TRAILING NEWLINE, which is what sops hands over
printf 'MyAccountPassw0rd\n' > "$root/password"

export FAKE_SECRET_FILE="$STATE/registration_shared_secret"
export FAKE_EXPECT_PASSWORD='MyAccountPassw0rd'

PORT=18831
"$PY" "$HERE/fake_synapse.py" "$PORT" "$root/seen.json" &
FAKE=$!
for _ in $(seq 1 100); do [ -e "$root/seen.json.running" ] && break; sleep 0.05; done

# Every execve and its argv, captured by ptrace rather than sampled. A
# /proc polling loop missed a curl that lived three milliseconds and
# reported three clean lines while the token was on its command line.
set +e
CREDENTIALS_DIRECTORY="$root" \
MX_LOCALPART=echo MX_ADMIN=1 MX_ISSUE_TOKEN=1 MX_DEVICE_ID=kmatrix-echo \
MX_DISPLAYNAME="Echo Bot" MX_ROOMS="#general:test" \
  strace -f -qq -s 4096 -e trace=execve -o "$root/argv.log" \
    "$PROVISION" > "$root/provision.out" 2> "$root/provision.err"
RC=$?
set -e

rm -f "$root/seen.json.running"
wait "$FAKE" 2>/dev/null || true

echo "--- provisioner stdout ---"; cat "$root/provision.out"
echo "--- provisioner stderr ---"; cat "$root/provision.err"
echo "--- exit $RC ---"

fail=0
[ "$RC" = 0 ] || { echo "FAIL  provisioner exited $RC"; fail=1; }

"$PY" - "$root/seen.json" <<'PY'
import json, sys
seen = json.load(open(sys.argv[1]))
bad = 0
r = seen.get("register")
if not r:
    print("FAIL  the homeserver never saw a register call"); bad = 1
else:
    print("ok    register mac verified" if r["mac_ok"] else "FAIL  register MAC did not verify")
    bad |= 0 if r["mac_ok"] else 1
    print("ok    register password matched, trailing newline stripped" if r["password_ok"]
          else "FAIL  register password did not match (trailing newline?)")
    bad |= 0 if r["password_ok"] else 1
if seen.get("displayname") == "Echo Bot":
    print("ok    display name set through a bearer-authenticated PUT")
else:
    print("FAIL  display name was", seen.get("displayname")); bad = 1
if seen.get("joins"):
    print("ok    joined", seen["joins"])
else:
    print("FAIL  no room join reached the homeserver"); bad = 1
sys.exit(bad)
PY
[ $? = 0 ] || fail=1

echo "--- strace captured $(grep -c execve "$root/argv.log") execve calls ---"
command -v grep >/dev/null || { echo "FAIL  grep is absent, every absence assertion below would be vacuous"; exit 1; }
[ "$(grep -c execve "$root/argv.log")" -ge 10 ] || { echo "FAIL  too few execve calls captured, strace did not follow"; fail=1; }
for needle in TOPSECRETsharedregistrationsecretAAAA MyAccountPassw0rd syt_fake_access_token_aaaaaaaaaaaa; do
  if grep -qF "$needle" "$root/argv.log"; then
    echo "FAIL  a secret appeared in a child's argv: ${needle:0:12}..."
    fail=1
  else
    echo "ok    ${needle:0:12}... never on any argv"
  fi
done

# Positive control: the capture must be capable of finding a planted secret.
strace -f -qq -s 4096 -e trace=execve -o "$root/control.log" \
  /bin/sh -c 'true MyAccountPassw0rd' 2>/dev/null || true
if grep -qF MyAccountPassw0rd "$root/control.log"; then
  echo "ok    positive control: argv reading does find a planted secret"
else
  echo "FAIL  positive control: argv reading found nothing, so the zeroes above mean nothing"
  fail=1
fi

exit "$fail"

rm -rf "$STATE"
