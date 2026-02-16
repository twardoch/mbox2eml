#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$ROOT_DIR/mbox2eml"
TMP_DIR=$(mktemp -d)
trap 'chmod -R u+w "$TMP_DIR" >/dev/null 2>&1 || true; rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_eq() {
  local actual=$1
  local expected=$2
  local msg=$3
  if [[ "$actual" != "$expected" ]]; then
    fail "$msg (expected=$expected actual=$actual)"
  fi
}

assert_contains() {
  local file=$1
  local needle=$2
  local msg=$3
  if ! grep -Fq "$needle" "$file"; then
    fail "$msg"
  fi
}

# 1) Missing input file must fail.
missing_out="$TMP_DIR/missing_out"
missing_log="$TMP_DIR/missing.log"
set +e
"$BIN" "$TMP_DIR/does-not-exist.mbox" "$missing_out" >"$missing_log" 2>&1
missing_rc=$?
set -e
if [[ $missing_rc -eq 0 ]]; then
  fail "missing input file should return non-zero"
fi
assert_contains "$missing_log" "does not exist" "missing input error message not found"

# 2) Preamble before first separator should be ignored.
preamble_mbox="$TMP_DIR/preamble.mbox"
cat >"$preamble_mbox" <<'MBOX'
This is a preamble line
From sender@example.com Sat Jan 01 00:00:00 2022
Subject: one

Body line
MBOX

preamble_out="$TMP_DIR/preamble_out"
"$BIN" "$preamble_mbox" "$preamble_out" >/dev/null 2>&1
preamble_count=$(find "$preamble_out" -maxdepth 1 -name 'email_*.eml' | wc -l | tr -d ' ')
assert_eq "$preamble_count" "1" "preamble should not create a synthetic email"
assert_contains "$preamble_out/email_1.eml" "Subject: one" "expected email content missing for preamble case"

# 3) Body lines that start with "From " but are not separators must not split email.
body_from_mbox="$TMP_DIR/body_from.mbox"
cat >"$body_from_mbox" <<'MBOX'
From sender@example.com Sat Jan 01 00:00:00 2022
Subject: two

Line A
From this line should stay in body
Line C
MBOX

body_from_out="$TMP_DIR/body_from_out"
"$BIN" "$body_from_mbox" "$body_from_out" >/dev/null 2>&1
body_from_count=$(find "$body_from_out" -maxdepth 1 -name 'email_*.eml' | wc -l | tr -d ' ')
assert_eq "$body_from_count" "1" "non-separator body line should not split email"
assert_contains "$body_from_out/email_1.eml" "From this line should stay in body" "body content lost due to false split"

# 4) Write failures must surface as non-zero exit.
write_fail_mbox="$TMP_DIR/write_fail.mbox"
cat >"$write_fail_mbox" <<'MBOX'
From sender@example.com Sat Jan 01 00:00:00 2022
Subject: write-fail

Body
MBOX

write_fail_out="$TMP_DIR/write_fail_out"
mkdir -p "$write_fail_out"
chmod 500 "$write_fail_out"
write_fail_log="$TMP_DIR/write_fail.log"
set +e
"$BIN" "$write_fail_mbox" "$write_fail_out" >"$write_fail_log" 2>&1
write_fail_rc=$?
set -e
chmod 700 "$write_fail_out"
if [[ $write_fail_rc -eq 0 ]]; then
  fail "write failure should return non-zero"
fi
assert_contains "$write_fail_log" "failed" "write failure log should mention failed writes"

# 5) Functional regression: multiple valid messages produce matching output count.
multi_mbox="$TMP_DIR/multi.mbox"
for i in $(seq 1 25); do
  {
    echo "From sender${i}@example.com Sat Jan 01 00:00:00 2022"
    echo "Subject: msg-${i}"
    echo
    echo "Body ${i}"
  } >>"$multi_mbox"
done

multi_out="$TMP_DIR/multi_out"
"$BIN" "$multi_mbox" "$multi_out" >/dev/null 2>&1
multi_count=$(find "$multi_out" -maxdepth 1 -name 'email_*.eml' | wc -l | tr -d ' ')
assert_eq "$multi_count" "25" "expected one output file per input message"
assert_contains "$multi_out/email_25.eml" "Subject: msg-25" "last output email content mismatch"

echo "All regression tests passed."
