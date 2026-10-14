#!/usr/bin/env bash
#
# sh/mayhem/test.sh — RUN the project's own Go test suite and a known-answer probe, and emit a
# CTRF summary. exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the load-bearing one:
#
#  1) `go test ./...` — upstream's suite is extensive: syntax/filetests_test.go and friends assert
#     exact parse trees and printed golden output for hundreds of cases; syntax/typedjson has its
#     own round-trip + error-message assertions. So it asserts BEHAVIOUR, not "exits 0".
#
#  2) The KAT probe /mayhem/kat — because `go test` links a STATIC binary, the verify-repo sabotage
#     check (LD_PRELOAD a shim whose constructor _exit(0)s every non-system executable) CANNOT
#     neuter it. A `go test`-only oracle therefore survives sabotage while proving nothing, which is
#     exactly the reward-hackable case the spec forbids. /mayhem/kat is built with cgo => DYNAMICALLY
#     linked, so the shim does neuter it; it then prints nothing and the exact-match assertions below
#     fail. The probe asserts two VALUES computed by feeding fixed input through the real parser +
#     printer + typedjson decoder (shfmt's whole job), so a patch that stubs the parser to stop a
#     crash cannot satisfy it either.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own Go suite ────────────────────────────────────────────────
if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 2
fi

echo "=== running: go test -json ./... ==="
mkdir -p "$SRC/mayhem-build"
JSON="$SRC/mayhem-build/gotest.json"
go test -json ./... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?
go test ./... 2>&1 | tail -30 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events only (lines carrying a non-empty "Test" field); package-level
# pass/fail lines have no "Test" field. Subtests count — they are real asserted cases.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test events parsed — the suite did not run (go exit $rc)" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 1
fi
# A non-zero go exit with zero counted failures means a build/vet error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ────────────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A `[ -f ... ]` guard
# here is how a probe silently stops running and the oracle quietly degrades to the
# go-test-only (reward-hackable) case. No fixture files are needed — the probe's fixed input
# (a shell snippet and a JSON literal) is compiled into /mayhem/kat itself.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed/printed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

# Expected values (computed once with the real parser/printer/typedjson decoder and pinned here):
#   KAT_PARSE_PRINT       messy "if [ a = b ];then echo x;fi\n" formats to the canonical
#                         "if [ a = b ]; then echo x; fi\n" (shfmt's whole job).
#   KAT_TYPEDJSON_DECODE  the fixed JSON literal {"Type":"File","Stmts":[...echo, hi...]} decodes
#                         to a syntax.Node that prints back as "echo hi\n".
kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or parser broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "parse+print round-trip (if/then/fi reflow)" 'KAT_PARSE_PRINT="if [ a = b ]; then echo x; fi\n"'
kat_expect "typedjson.Decode of a fixed JSON literal"   'KAT_TYPEDJSON_DECODE="echo hi\n"'

emit_ctrf "go-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
