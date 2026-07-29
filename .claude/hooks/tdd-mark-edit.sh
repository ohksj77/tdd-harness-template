#!/bin/sh
# tdd-mark-edit.sh — PostToolUse / Edit|Write|MultiEdit
#
# 편집이 실제로 일어난 뒤의 부기(簿記).
#   (a) src/test 편집 + IDLE|GREEN_VERIFIED → RED_PENDING
#   (b) 가드 대상(src/main) 편집 → 카운터 증가
#   (c) dirty-files에 적재 (Stop 시점 일괄 포매팅용)
#   (d) 최소 공백 정규화
#
# 종료 코드: 항상 0.

set -u

HOOK_DIR=$(dirname "$0")
# shellcheck source=./_lib.sh
. "$HOOK_DIR/_lib.sh" || exit 0

hook_read_stdin
[ -n "$HOOK_STDIN" ] || exit 0

TDD_SESSION_ID=$(json_get session_id)
TDD_TARGET=$(json_get tool_input.file_path)
[ -n "$TDD_TARGET" ] || TDD_TARGET=$(json_get tool_input.notebook_path)
[ -n "$TDD_TARGET" ] || exit 0

resolve_project_root || exit 0
case "$TDD_TARGET" in
"$PROJECT_ROOT"/*) : ;;
/*) exit 0 ;;
*) TDD_TARGET=$PROJECT_ROOT/$TDD_TARGET ;;
esac
ensure_state_dir || exit 0

TDD_STATE_NOW=$(current_state)

# --- (a) 테스트 편집 → RED_PENDING -------------------------------------------
if is_test_path "$TDD_TARGET"; then
	case "$TDD_STATE_NOW" in
	IDLE | GREEN_VERIFIED | '')
		state_set state=RED_PENDING red_kind= \
			failing_suites= failing_symbols= mentioned_types= \
			refactor_deadline= refactor_edits_used=0
		log_event edit-test "$TDD_STATE_NOW" RED_PENDING
		printf 'TDD: %s → RED_PENDING (테스트 편집됨). ./gradlew test 로 RED를 증명하세요.\n' "$TDD_STATE_NOW"
		;;
	esac
fi

# --- (b) 프로덕션 편집 → 카운터 ----------------------------------------------
if is_guarded_path "$TDD_TARGET"; then
	TDD_SINCE=$(state_get_or main_edits_since_green 0)
	TDD_SINCE=$((TDD_SINCE + 1))
	if [ "$TDD_STATE_NOW" = "REFACTOR" ]; then
		TDD_USED=$(state_get_or refactor_edits_used 0)
		TDD_USED=$((TDD_USED + 1))
		state_set main_edits_since_green="$TDD_SINCE" refactor_edits_used="$TDD_USED"
	else
		state_set main_edits_since_green="$TDD_SINCE"
	fi
fi

# --- (c)(d) 포매팅 대기열 + 최소 정규화 ---------------------------------------
# spotlessApply를 편집마다 돌리면 JVM 기동만 5~20초다. 여기서는 의미를 절대
# 바꿀 수 없는 두 변환만 하고, 진짜 포매팅은 Stop 훅으로 일괄 미룬다.
case "$TDD_TARGET" in
*.java | *.kt | *.kts) : ;;
*) exit 0 ;;
esac

[ -f "$TDD_TARGET" ] || exit 0

grep -qxF "$TDD_TARGET" "$STATE_DIR/dirty-files" 2>/dev/null ||
	printf '%s\n' "$TDD_TARGET" >>"$STATE_DIR/dirty-files" 2>/dev/null

if [ "$(cfg_get postEditNormalize true)" != "false" ]; then
	TDD_NORM=$STATE_DIR/.norm.$$
	awk '{ sub(/[ \t]+$/, ""); print }' "$TDD_TARGET" >"$TDD_NORM" 2>/dev/null
	if [ -s "$TDD_NORM" ] && ! cmp -s "$TDD_NORM" "$TDD_TARGET" 2>/dev/null; then
		# 바이트가 실제로 바뀔 때만 쓴다. 불필요한 쓰기는 Claude의 파일
		# 스냅샷을 어긋나게 해 다음 Edit이 문자열 불일치로 실패하게 만든다.
		cat "$TDD_NORM" >"$TDD_TARGET" 2>/dev/null
	fi
	rm -f "$TDD_NORM" 2>/dev/null
fi

exit 0
