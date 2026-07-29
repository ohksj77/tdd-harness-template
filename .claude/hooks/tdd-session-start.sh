#!/bin/sh
# tdd-session-start.sh — SessionStart
#
# 현재 TDD 상태를 세션 컨텍스트로 주입하고, 오래 방치된 상태를 회수한다.
# 종료 코드: 항상 0.

set -u

HOOK_DIR=$(dirname "$0")
# shellcheck source=./_lib.sh
. "$HOOK_DIR/_lib.sh" || exit 0

hook_read_stdin
TDD_SESSION_ID=$(json_get session_id)

resolve_project_root || exit 0
[ "$(cfg_get enabled true)" = "false" ] && exit 0
ensure_state_dir || exit 0

# stale 락 회수 — 이전 세션이 비정상 종료했을 수 있다.
if [ -d "$STATE_DIR/lock" ]; then
	TDD_AGE=$(lock_age_secs)
	[ "$TDD_AGE" -gt "$TDD_LOCK_STALE_SECS" ] 2>/dev/null && rm -rf "$STATE_DIR/lock" 2>/dev/null
fi

TDD_STATE_NOW=$(current_state)

# 24시간 넘게 방치된 상태는 신뢰할 수 없다 — 그 사이 코드가 바뀌었을 것이다.
if [ "$TDD_STATE_NOW" != "IDLE" ] && [ -f "$STATE_DIR/state" ]; then
	TDD_MT=$(mtime_epoch "$STATE_DIR/state")
	TDD_NOW=$(epoch_now)
	if [ -n "$TDD_MT" ] && [ "$((TDD_NOW - TDD_MT))" -gt 86400 ] 2>/dev/null; then
		log_event session-stale-reset "$TDD_STATE_NOW" IDLE
		state_reset
		printf 'TDD 하네스: 24시간 이상 방치된 %s 상태를 IDLE로 초기화했습니다.\n' "$TDD_STATE_NOW"
		exit 0
	fi
fi

# 세션 시작 시 상태를 알린다. 새 세션이 중단된 사이클을 모르고 진행하는 것이
# TDD 하네스에서 가장 흔한 혼란 원인이다.
case "$TDD_STATE_NOW" in
IDLE)
	printf 'TDD 하네스: 활성 (상태 IDLE). src/main 편집은 실패하는 테스트를 먼저 요구합니다.\n'
	;;
RED_PENDING)
	printf 'TDD 하네스: 이어받은 상태 RED_PENDING — 테스트가 수정됐지만 실행되지 않았습니다.\n'
	printf '            ./gradlew test 로 RED를 증명하고 이어가세요.\n'
	;;
RED_VERIFIED)
	printf 'TDD 하네스: 이어받은 상태 RED_VERIFIED — 실패 중인 테스트가 있습니다.\n'
	printf '            실패 스위트: %s\n' "$(state_get_or failing_suites '(기록 없음)')"
	printf '            지금 할 일: 이 테스트를 통과시키는 최소 구현.\n'
	;;
GREEN_VERIFIED)
	printf 'TDD 하네스: 이어받은 상태 GREEN_VERIFIED — 바가 초록입니다.\n'
	printf '            다음 동작은 새 실패 테스트부터. 리팩터링은 tdd-state.sh enter-refactor.\n'
	;;
REFACTOR)
	printf 'TDD 하네스: 이어받은 상태 REFACTOR — 리팩터링 창이 열려 있습니다.\n'
	printf '            끝나면 ./gradlew test 로 그린을 재확인하세요.\n'
	;;
esac

exit 0
