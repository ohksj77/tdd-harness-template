#!/bin/sh
# run-tests.sh — TDD 루프용 Gradle 테스트 실행 래퍼
#
#   run-tests.sh                       전체 (사이클 마감용)
#   run-tests.sh :core                 모듈 하나
#   run-tests.sh :core '*UserServiceTest'
#   run-tests.sh :core '*UserServiceTest.rejectsUnknownId'
#   run-tests.sh :core '*UserServiceTest' --rerun
#
# 세 가지를 강제한다:
#   1. --console=plain  — ANSI 커서 제어가 컴파일 오류 줄을 지우는 것을 막는다.
#      실패 분류가 로그에 의존하므로 이건 협상 불가다.
#   2. 전체 로그 tee    — 스크롤로 사라지지 않게 파일에 남긴다.
#   3. 실패 요약        — 무엇이 왜 실패했는지 한 화면에 보여준다.

set -u

MODULE=""
FILTER=""
RERUN=""

while [ $# -gt 0 ]; do
	case "$1" in
	--rerun) RERUN=--rerun-tasks ;;
	--clean) RERUN=--rerun-tasks ;;
	:*) MODULE=$1 ;;
	-*) ;;
	*) [ -z "$FILTER" ] && FILTER=$1 ;;
	esac
	shift
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
cd "$ROOT" || exit 1

if [ -x ./gradlew ]; then
	GRADLE=./gradlew
elif command -v gradle >/dev/null 2>&1; then
	GRADLE=gradle
	printf 'run-tests: gradlew 가 없어 시스템 gradle 을 씁니다.\n' >&2
else
	printf 'run-tests: gradle 을 찾을 수 없습니다.\n' >&2
	exit 1
fi

TASK=test
[ -n "$MODULE" ] && TASK="$MODULE:test"

LOGDIR=${TMPDIR:-/tmp}
LOG=$LOGDIR/tdd-gradle-$$.log

set -- "$TASK" --console=plain
[ -n "$FILTER" ] && set -- "$@" --tests "$FILTER"
[ -n "$RERUN" ] && set -- "$@" "$RERUN"

printf '▶ %s %s\n\n' "$GRADLE" "$*"
"$GRADLE" "$@" 2>&1 | tee "$LOG"
EXIT=$?

printf '\n'
HERE=$(dirname "$0")
if [ -x "$HERE/summarize-results.sh" ]; then
	"$HERE/summarize-results.sh" "$LOG"
fi

printf '\n전체 로그: %s\n' "$LOG"
exit $EXIT
