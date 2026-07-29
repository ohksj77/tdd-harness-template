#!/bin/sh
# tdd-state.sh — TDD 상태 머신 CLI (훅이 아니다)
#
# 에이전트와 사람이 상태를 조회하고 명시적으로 전이시키는 통로.
#
#   status          현재 상태 요약
#   explain         상태 머신과 다음에 할 일 안내
#   enter-refactor  GREEN_VERIFIED → REFACTOR (신선도 조건 충족 시)
#   grant-scaffold  신규 모듈 부트스트랩용 시간 제한 승인
#   bypass on|off   비상 우회 토글 (기록됨)
#   reset           IDLE로 초기화
#   events [n]      최근 감사 로그

set -u

HOOK_DIR=$(dirname "$0")
# shellcheck source=./_lib.sh
. "$HOOK_DIR/_lib.sh" || exit 1

HOOK_STDIN=""
TDD_SESSION_ID=cli

resolve_project_root || {
	printf 'tdd-state: 프로젝트 루트를 찾을 수 없습니다. 저장소 안에서 실행하세요.\n' >&2
	exit 1
}
ensure_state_dir || {
	printf 'tdd-state: %s 를 만들 수 없습니다.\n' "$STATE_DIR" >&2
	exit 1
}

# parse_duration 20m → 1200
parse_duration() {
	_pd=$1
	case "$_pd" in
	*s) printf '%s' "${_pd%s}" ;;
	*m) printf '%s' "$((${_pd%m} * 60))" ;;
	*h) printf '%s' "$((${_pd%h} * 3600))" ;;
	*) printf '%s' "$_pd" ;;
	esac
}

cmd_status() {
	_st=$(current_state)
	printf 'TDD 상태: %s\n' "$_st"
	printf '  경로       : %s\n' "$STATE_DIR"
	printf '  갱신       : %s\n' "$(state_get_or updated_at '-')"
	printf '  JSON 파서  : %s\n' "$(json_tier)"
	printf '  가드 활성  : %s (scopeMode=%s)\n' "$(cfg_get enabled true)" "$(cfg_get scopeMode warn)"
	case "$_st" in
	RED_VERIFIED)
		printf '  RED 종류   : %s\n' "$(state_get_or red_kind '-')"
		printf '  실패 스위트: %s\n' "$(state_get_or failing_suites '-')"
		printf '  미해결 심볼: %s\n' "$(state_get_or failing_symbols '-')"
		printf '  등장 타입  : %s\n' "$(state_get_or mentioned_types '-')"
		;;
	GREEN_VERIFIED)
		printf '  그린 이후 src/main 편집: %s회\n' "$(state_get_or main_edits_since_green 0)"
		;;
	REFACTOR)
		_dl=$(state_get_or refactor_deadline 0)
		_now=$(epoch_now)
		printf '  남은 시간  : %s초\n' "$((_dl - _now))"
		printf '  편집 예산  : %s / %s\n' \
			"$(state_get_or refactor_edits_used 0)" "$(state_get_or refactor_edit_budget 40)"
		;;
	esac
	_sg=$(state_get scaffold_glob)
	if [ -n "$_sg" ]; then
		_se=$(state_get_or scaffold_expires 0)
		_now=$(epoch_now)
		if [ "$_now" -lt "$_se" ] 2>/dev/null; then
			printf '  스캐폴딩   : %s (남은 %s초, 사유: %s)\n' \
				"$_sg" "$((_se - _now))" "$(state_get_or scaffold_reason '-')"
		fi
	fi
	[ -f "$STATE_DIR/BYPASS" ] && printf '  ⚠ BYPASS 활성 — 가드가 통과만 시키고 있습니다.\n'
	return 0
}

cmd_explain() {
	cat <<'EOF'
TDD 상태 머신

  IDLE ──src/test 편집──> RED_PENDING ──gradle: red──> RED_VERIFIED
                               │                            │
                               └──gradle: green───> GREEN_VERIFIED <──┐
                                                          │           │
                                           enter-refactor │      gradle: green
                                                          ↓      / 예산 소진
                                                      REFACTOR ───────┘

src/main/{java,kotlin} 편집이 허용되는 상태: RED_VERIFIED, REFACTOR
그 외 파일(빌드 스크립트, 리소스, 테스트, 문서)은 상태와 무관하게 항상 허용된다.

RED로 인정되는 것
  · 어서션 실패 (TEST-*.xml 의 failures/errors > 0)
  · 테스트 소스 컴파일 실패 (cannot find symbol / Unresolved reference)
    ← JVM에서 첫 RED는 대부분 이 모양이다. 정당한 RED로 취급한다.

RED가 아닌 것
  · 프로덕션 소스 컴파일 실패 — 되돌려야 한다
  · 의존성 해석/네트워크/Docker 오류 — 환경 문제
  · UP-TO-DATE로 새 결과가 없는 경우 — cleanTest 또는 --rerun-tasks

막혔을 때
  1) tdd-state.sh status 로 현재 상태와 실패 스위트를 본다
  2) RED_PENDING이면 테스트를 실제로 실행한다
  3) GREEN_VERIFIED인데 프로덕션을 고쳐야 하면, 새 실패 테스트를 쓰거나
     리팩터링임을 선언한다 (enter-refactor)
  4) 신규 모듈 뼈대처럼 테스트가 선행할 수 없으면 grant-scaffold
EOF
	return 0
}

cmd_enter_refactor() {
	_st=$(current_state)
	if [ "$_st" != "GREEN_VERIFIED" ]; then
		printf 'enter-refactor 거부: 현재 상태가 %s 입니다. GREEN_VERIFIED 에서만 진입할 수 있습니다.\n' "$_st" >&2
		printf '먼저 ./gradlew test 로 초록을 확인하세요.\n' >&2
		return 1
	fi
	_since=$(state_get_or main_edits_since_green 0)
	if [ "$_since" -gt 0 ] 2>/dev/null; then
		printf 'enter-refactor 거부: 마지막 그린 이후 src/main이 %s회 변경되었습니다.\n' "$_since" >&2
		printf './gradlew test 를 다시 실행해 여전히 초록인지 확인하세요.\n' >&2
		return 1
	fi
	_green=$(state_get_or green_at 0)
	_now=$(epoch_now)
	if [ "$((_now - _green))" -gt 900 ] 2>/dev/null; then
		printf 'enter-refactor 거부: 마지막 초록이 %s초 전입니다 (허용 900초).\n' "$((_now - _green))" >&2
		printf '그 사이 무엇이 바뀌었는지 알 수 없습니다. ./gradlew test 를 다시 실행하세요.\n' >&2
		return 1
	fi

	_ttl=${TDD_REFACTOR_TTL:-1800}
	_budget=$(state_get_or refactor_edit_budget 40)
	state_set state=REFACTOR refactor_deadline="$((_now + _ttl))" \
		refactor_edits_used=0 refactor_edit_budget="$_budget"
	log_event enter-refactor GREEN_VERIFIED REFACTOR
	printf '리팩터링 창을 열었습니다: %s초, 편집 예산 %s회.\n' "$_ttl" "$_budget"
	printf '동작을 바꾸지 마세요. 테스트가 한 번이라도 빨개지면 즉시 되돌립니다.\n'
	printf '끝나면 ./gradlew test 로 그린을 재확인하세요.\n'
	return 0
}

cmd_grant_scaffold() {
	_glob=""
	_reason=""
	_ttl=1200
	while [ $# -gt 0 ]; do
		case "$1" in
		--glob)
			_glob=${2:-}
			shift 2
			;;
		--reason)
			_reason=${2:-}
			shift 2
			;;
		--ttl)
			_ttl=$(parse_duration "${2:-20m}")
			shift 2
			;;
		*) shift ;;
		esac
	done
	if [ -z "$_glob" ] || [ -z "$_reason" ]; then
		printf 'usage: tdd-state.sh grant-scaffold --glob <경로글롭> --reason <사유> [--ttl 20m]\n' >&2
		return 1
	fi
	_now=$(epoch_now)
	state_set scaffold_glob="$_glob" scaffold_expires="$((_now + _ttl))" \
		scaffold_reason="$(printf '%s' "$_reason" | tr ' ' '-')"
	log_event grant-scaffold "$_glob" "$_reason"
	printf '스캐폴딩 승인: %s (%s초). 사유: %s\n' "$_glob" "$_ttl" "$_reason"
	printf '시간 제한이며 감사 로그에 남습니다. 뼈대가 서면 바로 테스트부터 쓰세요.\n'
	return 0
}

cmd_bypass() {
	case "${1:-}" in
	on)
		: >"$STATE_DIR/BYPASS"
		log_event bypass-on "" ""
		printf 'BYPASS 활성. 가드가 src/main 편집을 막지 않습니다.\n'
		printf '끝나면 반드시: tdd-state.sh bypass off\n'
		;;
	off)
		rm -f "$STATE_DIR/BYPASS"
		log_event bypass-off "" ""
		printf 'BYPASS 해제.\n'
		;;
	*)
		if [ -f "$STATE_DIR/BYPASS" ]; then printf 'BYPASS: on\n'; else printf 'BYPASS: off\n'; fi
		;;
	esac
	return 0
}

cmd_reset() {
	_st=$(current_state)
	state_reset
	rm -f "$STATE_DIR/BYPASS" 2>/dev/null
	log_event reset "$_st" IDLE
	printf 'TDD 상태를 IDLE로 초기화했습니다 (이전: %s).\n' "$_st"
	return 0
}

cmd_events() {
	_n=${1:-20}
	[ -f "$STATE_DIR/events.log" ] || {
		printf '(감사 로그 없음)\n'
		return 0
	}
	tail -n "$_n" "$STATE_DIR/events.log"
	return 0
}

TDD_SUBCMD=${1:-status}
[ $# -gt 0 ] && shift

case "$TDD_SUBCMD" in
status) cmd_status ;;
explain) cmd_explain ;;
enter-refactor) cmd_enter_refactor ;;
grant-scaffold) cmd_grant_scaffold "$@" ;;
bypass) cmd_bypass "$@" ;;
reset) cmd_reset ;;
events) cmd_events "$@" ;;
-h | --help | help)
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	;;
*)
	printf 'tdd-state: 알 수 없는 명령 "%s". --help 를 보세요.\n' "$TDD_SUBCMD" >&2
	exit 1
	;;
esac
