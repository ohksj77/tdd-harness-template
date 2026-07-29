#!/bin/sh
# tdd-guard-pre-edit.sh — PreToolUse / Edit|Write|MultiEdit|NotebookEdit
#
# RED→GREEN→REFACTOR 사이클을 강제하는 유일한 차단 지점.
#
# 종료 코드 계약:
#   0  허용 (조용히, 또는 stdout 경고와 함께)
#   2  차단 — stderr가 곧바로 Claude 컨텍스트로 들어간다
#   그 외 종료 코드는 내지 않는다. 내부 오류는 전부 fail open(0).
#
# 불변식: 이 스크립트는 상태를 절대 쓰지 않는다.
# 같은 이벤트의 훅들은 병렬 실행되고 서로의 출력을 보지 못하므로,
# 상태를 변경하는 PreToolUse 훅은 비결정적이 된다.
# (events.log 추가만 예외 — append-only라 경쟁하지 않는다.)

set -u

HOOK_DIR=$(dirname "$0")
# shellcheck source=./_lib.sh
. "$HOOK_DIR/_lib.sh" || exit 0

TDD_STATE_NOW=""
TDD_TARGET=""

deny() {
	printf '%s\n' "$1" >&2
	log_event deny "$TDD_STATE_NOW" "$TDD_TARGET"
	exit 2
}

allow_quiet() { exit 0; }

allow_noting() {
	printf '%s\n' "$1"
	exit 0
}

# --- 0. 입력 파싱. 실패하면 fail open ---------------------------------------
hook_read_stdin
[ -n "$HOOK_STDIN" ] || exit 0

TDD_SESSION_ID=$(json_get session_id)
TDD_TARGET=$(json_get tool_input.file_path)
[ -n "$TDD_TARGET" ] || TDD_TARGET=$(json_get tool_input.notebook_path)

# 경로를 못 뽑았으면 판단 근거가 없다 → 통과
[ -n "$TDD_TARGET" ] || exit 0

# --- 1. 프로젝트 루트 해석 ---------------------------------------------------
resolve_project_root || exit 0

case "$TDD_TARGET" in
"$PROJECT_ROOT"/*) : ;;
/*) exit 0 ;; # 프로젝트 밖의 절대 경로는 우리 소관이 아니다
*) TDD_TARGET=$PROJECT_ROOT/$TDD_TARGET ;;
esac

# --- 2. 가드 스코프 — 가장 중요한 좁히기 -------------------------------------
# 프로덕션 JVM 소스만 지킨다. build.gradle.kts, application.yml, src/test/**,
# .claude/**, 문서 등은 상태를 보기도 전에 통과한다.
is_guarded_path "$TDD_TARGET" || exit 0

# --- 3. 설정 게이트 ----------------------------------------------------------
[ "$(cfg_get enabled true)" = "false" ] && exit 0

TDD_ALLOWS=$(cfg_list allowPatterns)
if [ -n "$TDD_ALLOWS" ]; then
	# 서브셸을 피하려고 IFS를 개행으로 두고 for를 돈다.
	# (파이프의 while은 서브셸이라 여기서 exit 해도 스크립트가 끝나지 않는다.)
	_old_ifs=$IFS
	IFS='
'
	for _pat in $TDD_ALLOWS; do
		[ -n "$_pat" ] || continue
		if glob_match "$TDD_TARGET" "$_pat"; then
			IFS=$_old_ifs
			exit 0
		fi
	done
	IFS=$_old_ifs
fi

# --- 4. 탈출구 (모두 기록된다 — 비밀 우회는 없다) ----------------------------
if [ "${TDD_GUARD:-}" = "off" ]; then
	log_event bypass-env "" "$TDD_TARGET"
	exit 0
fi

if [ -n "$STATE_DIR" ] && [ -f "$STATE_DIR/BYPASS" ]; then
	log_event bypass-file "" "$TDD_TARGET"
	printf 'TDD 가드 우회 중 (.tdd-state/BYPASS 존재). 끝나면 파일을 지우세요.\n'
	exit 0
fi

TDD_SCAFFOLD_GLOB=$(state_get scaffold_glob)
if [ -n "$TDD_SCAFFOLD_GLOB" ]; then
	TDD_SCAFFOLD_EXP=$(state_get_or scaffold_expires 0)
	TDD_NOW_EPOCH=$(epoch_now)
	if [ "$TDD_NOW_EPOCH" -lt "$TDD_SCAFFOLD_EXP" ] 2>/dev/null &&
		glob_match "$TDD_TARGET" "$TDD_SCAFFOLD_GLOB"; then
		log_event bypass-scaffold "" "$TDD_TARGET"
		printf 'TDD: 스캐폴딩 승인으로 허용됨 (만료까지 %s초). 사유: %s\n' \
			"$((TDD_SCAFFOLD_EXP - TDD_NOW_EPOCH))" "$(state_get scaffold_reason)"
		exit 0
	fi
fi

# --- 5. 상태 게이트 (하드 차단) ----------------------------------------------
TDD_STATE_NOW=$(current_state)

case "$TDD_STATE_NOW" in
RED_VERIFIED) : ;; # → 6단계 스코프 검사
REFACTOR) : ;;     # → 7단계 예산 검사
GREEN_VERIFIED)
	deny "TDD 가드: 바가 초록입니다. 지금은 src/main을 편집할 수 없습니다.

다음 중 하나를 먼저 하세요.
  (a) 새 동작을 추가하는 중이라면 — src/test 아래에 실패하는 테스트를 작성하고
      ./gradlew test --tests '<YourTest>' 로 RED를 증명하세요.
      (컴파일 실패도 정당한 RED로 인정됩니다.)
  (b) 동작을 바꾸지 않는 리팩터링이라면 —
      ./.claude/hooks/tdd-state.sh enter-refactor

대상: $TDD_TARGET"
	;;
RED_PENDING)
	deny "TDD 가드: 테스트를 수정했지만 아직 실행하지 않았습니다.

./gradlew <module>:test --tests '<YourTest>' 를 실행해 RED를 증명한 뒤 다시 시도하세요.
컴파일 실패(cannot find symbol / Unresolved reference)도 정당한 RED입니다.

상태 확인: ./.claude/hooks/tdd-state.sh status
대상: $TDD_TARGET"
	;;
*)
	deny "TDD 가드: 진행 중인 TDD 사이클이 없습니다 (상태: $TDD_STATE_NOW).

src/test 아래에 이 변경을 요구하는 실패 테스트를 먼저 작성하고 실행하세요.
신규 모듈 부트스트랩처럼 테스트보다 뼈대가 먼저인 경우에만:
  ./.claude/hooks/tdd-state.sh grant-scaffold --glob '<경로글롭>' --reason '<사유>' --ttl 20m

상태 확인: ./.claude/hooks/tdd-state.sh status
대상: $TDD_TARGET"
	;;
esac

# --- 6. REFACTOR 예산 검사 ---------------------------------------------------
if [ "$TDD_STATE_NOW" = "REFACTOR" ]; then
	TDD_DEADLINE=$(state_get_or refactor_deadline 0)
	TDD_NOW_EPOCH=$(epoch_now)
	if [ "$TDD_NOW_EPOCH" -ge "$TDD_DEADLINE" ] 2>/dev/null; then
		deny "TDD 가드: 리팩터링 시간 창이 만료되었습니다.

./gradlew test 로 그린을 재확인한 뒤 enter-refactor 를 다시 실행하세요.
대상: $TDD_TARGET"
	fi
	TDD_USED=$(state_get_or refactor_edits_used 0)
	TDD_BUDGET=$(state_get_or refactor_edit_budget 40)
	if [ "$TDD_USED" -ge "$TDD_BUDGET" ] 2>/dev/null; then
		deny "TDD 가드: 리팩터링 편집 예산(${TDD_BUDGET}회)을 소진했습니다.

./gradlew test 로 그린을 재확인하세요. 초록이면 예산이 초기화됩니다.
한 번에 이만큼 고쳐야 한다면 리팩터링 단위가 너무 큽니다 — 쪼개세요.
대상: $TDD_TARGET"
	fi
	allow_quiet
fi

# --- 7. RED_VERIFIED 스코프 검사 ---------------------------------------------
# "이 실패 테스트가 이 파일 편집을 정당화하는가?"
# 페이즈 게이트와 달리 이건 기본적으로 소프트 경고다. OrderServiceTest가
# 다른 패키지의 새 Money 타입을 요구하는 건 정상적인 설계이고, 그걸 하드
# 차단하는 가드는 하루 만에 꺼진다.

TDD_SCOPE_MODE=$(cfg_get scopeMode warn)
[ "$TDD_SCOPE_MODE" = "off" ] && allow_quiet

TDD_SIMPLE=$(path_simple_name "$TDD_TARGET")
TDD_PKG=$(path_package "$TDD_TARGET")
TDD_MENTIONED=$(state_get mentioned_types)
TDD_SYMBOLS=$(state_get failing_symbols)
TDD_SUITES=$(state_get failing_suites)

scope_matches() {
	# (a) 스택트레이스에 등장 — 가장 강한 신호
	in_csv "$TDD_SIMPLE" "$TDD_MENTIONED" && return 0
	# (b) compile-red 미해결 심볼
	in_csv "$TDD_SIMPLE" "$TDD_SYMBOLS" && return 0

	_sm_old_ifs=$IFS
	IFS=,
	for _sm_suite in $TDD_SUITES; do
		[ -n "$_sm_suite" ] || continue
		_sm_base=${_sm_suite##*.}
		_sm_stem=$(strip_test_suffix "$_sm_base")
		_sm_pkg=${_sm_suite%.*}
		[ "$_sm_pkg" = "$_sm_suite" ] && _sm_pkg=""

		# (c) UserServiceTest → UserService / UserServiceImpl
		if [ -n "$_sm_stem" ]; then
			case "$TDD_SIMPLE" in
			"$_sm_stem" | "$_sm_stem"*) IFS=$_sm_old_ifs && return 0 ;;
			esac
			case "$_sm_stem" in
			"$TDD_SIMPLE"*) IFS=$_sm_old_ifs && return 0 ;;
			esac
		fi

		# (d) 패키지 일치 또는 한쪽이 다른 쪽의 접두
		if [ -n "$_sm_pkg" ] && [ -n "$TDD_PKG" ]; then
			case "$TDD_PKG" in
			"$_sm_pkg" | "$_sm_pkg".*) IFS=$_sm_old_ifs && return 0 ;;
			esac
			case "$_sm_pkg" in
			"$TDD_PKG".*) IFS=$_sm_old_ifs && return 0 ;;
			esac
		fi
	done
	IFS=$_sm_old_ifs
	return 1
}

if scope_matches; then
	allow_quiet
fi

TDD_SCOPE_MSG="$TDD_TARGET 은(는) 현재 실패 테스트와 직접 연결되지 않습니다.
  실패 스위트: ${TDD_SUITES:-(없음)}
  미해결 심볼: ${TDD_SYMBOLS:-(없음)}
꼭 필요하면 진행하되, 가능하면 이 파일을 직접 겨냥한 실패 테스트를 먼저 쓰는 편이 사이클이 좁아집니다."

if [ "$TDD_SCOPE_MODE" = "strict" ]; then
	deny "TDD 가드 (strict 스코프): $TDD_SCOPE_MSG"
fi

log_event scope-warn "$TDD_STATE_NOW" "$TDD_TARGET"
allow_noting "TDD 경고: $TDD_SCOPE_MSG"
