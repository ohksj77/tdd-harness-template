#!/bin/sh
# tests/run-all.sh — 전체 검증 진입점
#
#   ./tests/run-all.sh          Layer 1~2 + 구조 검증 (JVM 불필요, 수 초)
#   ./tests/run-all.sh --e2e    실제 Gradle E2E 까지 (수 분, JDK 필요)

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
RUN_E2E=0
[ "${1:-}" = "--e2e" ] && RUN_E2E=1

FAILED=""
run() {
	printf '\n══ %s\n' "$1"
	shift
	if "$@"; then :; else FAILED="$FAILED\n  · $1"; fi
}

run "Layer 1 · 훅 결정표 (/bin/sh)" "$HERE/hooks/run.sh"
run "Layer 1 · 훅 결정표 (/bin/dash, POSIX 적합성)" "$HERE/hooks/run.sh" --shell /bin/dash
run "Layer 1 · JSON awk 폴백 단계" "$HERE/hooks/run.sh" --tier awk
run "Layer 2 · settings 병합" "$HERE/install/merge-settings.test.sh"
run "Layer 2 · 심링크/복사/제거" "$HERE/install/symlink-copy.test.sh"
run "Layer 4 · Harness 규약 구조 검증" "$HERE/harness/structure.test.sh"

if command -v shellcheck >/dev/null 2>&1; then
	printf '\n══ shellcheck (POSIX sh)\n'
	if shellcheck -s sh "$ROOT"/.claude/hooks/*.sh "$ROOT"/install.sh "$HERE"/run-all.sh; then
		printf '  ok   경고 없음\n'
	else
		FAILED="$FAILED\n  · shellcheck"
	fi
else
	printf '\n══ shellcheck — 미설치, 건너뜀 (brew install shellcheck)\n'
fi

if [ "$RUN_E2E" = "1" ]; then
	run "Layer 3 · 실제 Gradle E2E" "$HERE/e2e/tdd-cycle.sh"
else
	printf '\n══ Layer 3 · 실제 Gradle E2E — 건너뜀 (--e2e 로 실행)\n'
fi

printf '\n'
if [ -z "$FAILED" ]; then
	printf '전체 통과.\n'
	exit 0
fi
printf '실패한 스위트:'
printf "$FAILED\n"
exit 1
