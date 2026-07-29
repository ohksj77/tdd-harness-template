#!/bin/sh
# tdd-verify-stop.sh — Stop
#
# 세션을 미완결 상태로 끝내지 못하게 막는 최종 게이트 + 일괄 포매팅.
#
# 종료 코드:
#   0  종료 허용
#   2  차단 (stderr가 Claude 컨텍스트로)
#
# 루프 캡: 세션당 최대 2회만 차단한다. Harness의 생성-검증 재시도 상한과
# 같은 원칙이며 협상 불가다 — 무한 루프는 훅 게이트의 최악 실패 모드다.

set -u

HOOK_DIR=$(dirname "$0")
# shellcheck source=./_lib.sh
. "$HOOK_DIR/_lib.sh" || exit 0

hook_read_stdin

TDD_SESSION_ID=$(json_get session_id)

# --- 1. Claude Code 자체 재진입 가드 ------------------------------------------
[ "$(json_get stop_hook_active)" = "true" ] && exit 0

resolve_project_root || exit 0
[ -d "$STATE_DIR" ] || exit 0

# --- 2. 루프 캡 --------------------------------------------------------------
TDD_BLOCKS=$(state_get_or stop_block_count 0)
if [ "$TDD_BLOCKS" -ge 2 ] 2>/dev/null; then
	printf 'TDD: 이 세션에서 종료를 이미 2회 차단했습니다. 강제로 종료를 허용합니다.\n'
	printf '     남은 상태: %s — 다음 세션에서 이어서 처리하세요.\n' "$(current_state)"
	log_event stop-cap-reached "$(current_state)" ""
	exit 0
fi

# --- 3. 일괄 포매팅 ----------------------------------------------------------
if [ "$(cfg_get formatOnStop true)" != "false" ] &&
	[ -s "$STATE_DIR/dirty-files" ] &&
	[ -x "$PROJECT_ROOT/gradlew" ]; then

	# 태스크 존재 여부는 한 번만 조사하고 캐시한다 (조사 자체가 JVM 기동).
	if [ ! -f "$STATE_DIR/format-task" ]; then
		TDD_TASKS=$(cd "$PROJECT_ROOT" && ./gradlew -q tasks --all --console=plain 2>/dev/null)
		case "$TDD_TASKS" in
		*spotlessApply*) printf 'spotlessApply\n' >"$STATE_DIR/format-task" ;;
		*ktlintFormat*) printf 'ktlintFormat\n' >"$STATE_DIR/format-task" ;;
		*) printf 'none\n' >"$STATE_DIR/format-task" ;;
		esac
	fi
	TDD_FMT=$(head -1 "$STATE_DIR/format-task" 2>/dev/null)
	if [ -n "$TDD_FMT" ] && [ "$TDD_FMT" != "none" ]; then
		(cd "$PROJECT_ROOT" && ./gradlew -q "$TDD_FMT" --console=plain >/dev/null 2>&1)
		log_event format-batch "$TDD_FMT" "$(wc -l <"$STATE_DIR/dirty-files" 2>/dev/null | tr -d ' ')"
	fi
	: >"$STATE_DIR/dirty-files" 2>/dev/null
fi

# --- 4. 세션 중 사용된 우회 보고 (탈출구를 비밀로 두지 않는다) ----------------
if [ -f "$STATE_DIR/events.log" ]; then
	TDD_BYPASSES=$(grep -c 'bypass-' "$STATE_DIR/events.log" 2>/dev/null | tr -d ' ')
	[ -n "$TDD_BYPASSES" ] || TDD_BYPASSES=0
	if [ "$TDD_BYPASSES" -gt 0 ] 2>/dev/null; then
		printf 'TDD: 가드 우회가 누적 %s회 기록되어 있습니다 (.tdd-state/events.log).\n' "$TDD_BYPASSES"
		printf '     같은 유형이 반복된다면 가드 설정이 아니라 하네스를 손봐야 한다는 신호입니다.\n'
	fi
fi

# --- 5. 상태 검사 ------------------------------------------------------------
TDD_STATE_NOW=$(current_state)

block() {
	printf '%s\n' "$1" >&2
	state_set stop_block_count="$((TDD_BLOCKS + 1))"
	log_event stop-block "$TDD_STATE_NOW" ""
	exit 2
}

case "$TDD_STATE_NOW" in
RED_PENDING)
	block "TDD 게이트: 테스트를 작성했지만 실행하지 않은 채 끝내려 합니다.

./gradlew test --tests '<YourTest>' 를 실행해 RED를 확인하세요.
정말 중단하려면 테스트를 되돌리거나 ./.claude/hooks/tdd-state.sh reset 을 실행하세요."
	;;
RED_VERIFIED)
	TDD_FAILING=$(state_get failing_suites)
	[ -n "$TDD_FAILING" ] || TDD_FAILING="?"
	block "TDD 게이트: RED 상태로 끝낼 수 없습니다 (실패: $TDD_FAILING).

구현으로 초록을 만들거나, 이번 사이클을 포기한다면 테스트를 되돌리세요.
상태 초기화: ./.claude/hooks/tdd-state.sh reset"
	;;
REFACTOR)
	block "TDD 게이트: 리팩터링 중입니다.

./gradlew test 로 그린을 재확인한 뒤 종료하세요."
	;;
GREEN_VERIFIED)
	TDD_SINCE=$(state_get_or main_edits_since_green 0)
	if [ "$TDD_SINCE" -gt 0 ] 2>/dev/null; then
		block "TDD 게이트: 마지막 그린 이후 src/main이 ${TDD_SINCE}회 변경되었습니다.

./gradlew test 를 다시 실행해 여전히 초록인지 확인하세요."
	fi
	;;
esac

exit 0
