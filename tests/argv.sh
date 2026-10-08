#!/usr/bin/env bash
# Defends: no secret reaches a child process's argv.
#
# /proc/<pid>/cmdline is readable across uids on the host these units run
# on, so anything on a command line is readable by every local account for
# the life of the child. These assertions run against the generated
# provisioner and admin CLI, the same scripts systemd executes.
set -uo pipefail

PROVISION="$1"
ADMIN="$2"
fail=0

check_absent() {
  local file="$1" label="$2" pattern="$3"
  if grep -qE -- "$pattern" "$file"; then
    echo "FAIL  $label: $(grep -nE -- "$pattern" "$file" | head -1)"
    fail=1
  else
    echo "ok    $label"
  fi
}

check_present() {
  local file="$1" label="$2" pattern="$3"
  if grep -qE -- "$pattern" "$file"; then
    echo "ok    $label"
  else
    echo "FAIL  $label: expected to find /$pattern/ and did not"
    fail=1
  fi
}

echo "== provisioner =="
check_absent "$PROVISION" "no hmac key on openssl argv"        'openssl .*-hmac'
check_absent "$PROVISION" "openssl is not a runtime input"     'openssl-[0-9][^/]*/bin'
check_absent "$PROVISION" "no password through jq --arg"       '--arg +p '
check_absent "$PROVISION" "no body on curl argv"               '-d "[$]'
check_absent "$PROVISION" "no bearer token on curl argv"       'Authorization: Bearer \$'
check_absent "$PROVISION" "no --data with an inline value"     '--data [^@]'
check_present "$PROVISION" "password enters jq from a file"    '--rawfile p '
check_present "$PROVISION" "curl reads options from a file"    'curl --config'
check_present "$PROVISION" "hmac key is named as a path"       'kmatrix-hmac-sha1 '

echo "== admin cli =="
check_absent "$ADMIN" "no bearer token on curl argv"           'Authorization: Bearer \$'
check_absent "$ADMIN" "no body on curl argv"                   '-d "[$]'
check_present "$ADMIN" "curl reads options from a file"        'curl --config'

echo "== the shared secret is never interpolated into the store =="
check_absent "$PROVISION" "secret is read at runtime, not baked" 'registration_shared_secret"? *=.*[A-Za-z0-9+/]{32}'
check_present "$PROVISION" "secret is named as a path"           'registration_shared_secret'

exit "$fail"
