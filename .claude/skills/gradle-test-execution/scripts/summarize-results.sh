#!/bin/sh
# summarize-results.sh — 테스트 결과를 한 화면으로 요약하고 실패를 분류한다.
#
#   summarize-results.sh                 최신 결과 XML 을 스캔
#   summarize-results.sh <gradle.log>    로그도 함께 분류 (컴파일 실패 판별용)
#
# 분류는 TDD 상태 머신(.claude/hooks/tdd-record-run.sh)과 같은 기준을 쓴다.

set -u

LOG=${1:-}
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)

XML_FILES=$(find "$ROOT" -type f -name 'TEST-*.xml' -path '*/build/test-results/*' 2>/dev/null)

if [ -n "$XML_FILES" ]; then
	printf '%s\n' "$XML_FILES" | while IFS= read -r f; do
		[ -f "$f" ] && cat "$f"
	done | awk '
    /<testsuite[ \t]/ {
        line = $0
        t = 0; f = 0; e = 0; s = 0; nm = ""
        if (match(line, /tests="[0-9]+"/))    t  = substr(line, RSTART+7,  RLENGTH-8)
        if (match(line, /failures="[0-9]+"/)) f  = substr(line, RSTART+10, RLENGTH-11)
        if (match(line, /errors="[0-9]+"/))   e  = substr(line, RSTART+8,  RLENGTH-9)
        if (match(line, /skipped="[0-9]+"/))  s  = substr(line, RSTART+9,  RLENGTH-10)
        if (match(line, /[ \t]name="[^"]*"/)) nm = substr(line, RSTART+7,  RLENGTH-8)
        T += t; F += f; E += e; S += s
        if (f + e > 0) bad = bad sprintf("  ✗ %s  (실패 %d, 오류 %d)\n", nm, f, e)
    }
    /<(failure|error)[ \t>]/ {
        line = $0
        if (match(line, /message="[^"]*"/)) {
            msg = substr(line, RSTART+9, RLENGTH-10)
            if (length(msg) > 110) msg = substr(msg, 1, 110) "…"
            msgs = msgs "      " msg "\n"
        }
    }
    END {
        if (T == 0) { print "테스트 결과 XML 없음 (실행되지 않았거나 UP-TO-DATE)"; exit }
        printf "테스트 %d개  ·  실패 %d  ·  오류 %d  ·  건너뜀 %d\n", T, F, E, S
        if (F + E > 0) {
            printf "\n실패한 스위트:\n%s", bad
            if (msgs != "") printf "\n메시지:\n%s", msgs
        } else {
            printf "\n초록.\n"
        }
    }
    '
else
	printf '테스트 결과 XML 없음.\n'
fi

# 로그 기반 분류 — XML 이 없을 때 무슨 일이 있었는지가 여기 있다.
[ -n "$LOG" ] && [ -f "$LOG" ] || exit 0

printf '\n판정: '
if grep -qE 'compileTest(Java|Kotlin)[A-Za-z]* FAILED' "$LOG" 2>/dev/null &&
	grep -qE 'cannot find symbol|Unresolved reference|does not exist' "$LOG" 2>/dev/null; then
	printf 'compile-red — 테스트 소스가 컴파일되지 않습니다.\n'
	printf '  정당한 RED 입니다. 컴파일러가 첫 어서션 역할을 하고 있습니다.\n'
	printf '  아직 없는 심볼:\n'
	grep -hoE 'symbol: *(class|method|variable|interface) *[A-Za-z_$][A-Za-z0-9_$]*|Unresolved reference:? *[A-Za-z_$][A-Za-z0-9_$]*' "$LOG" 2>/dev/null |
		awk '{ print "    · " $NF }' | sort -u | head -20
elif grep -qE '> Task :[^ ]*:compile(Java|Kotlin)[A-Za-z]* FAILED' "$LOG" 2>/dev/null; then
	printf 'main-compile-broken — 프로덕션 소스가 컴파일되지 않습니다.\n'
	printf '  RED 가 아닙니다. 직전 변경을 되돌리세요.\n'
elif grep -qE 'Could not resolve|Connection refused|Could not find or load|Docker|Testcontainers' "$LOG" 2>/dev/null; then
	printf 'infra-red — 환경 문제입니다 (의존성·네트워크·Docker).\n'
	printf '  RED 가 아닙니다. 테스트를 고치지 마세요.\n'
elif grep -q 'UP-TO-DATE' "$LOG" 2>/dev/null && ! grep -q '<testsuite' /dev/null 2>&1; then
	printf 'no-fresh-results — 변경이 없어 테스트가 건너뛰어졌을 수 있습니다.\n'
	printf '  강제 재실행: --rerun-tasks 또는 cleanTest\n'
elif grep -q 'BUILD SUCCESSFUL' "$LOG" 2>/dev/null; then
	printf 'green\n'
else
	printf 'assertion-red 또는 분류 불가 — 위 실패 메시지를 확인하세요.\n'
fi
