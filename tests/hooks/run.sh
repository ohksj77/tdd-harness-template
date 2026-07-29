#!/bin/sh
# tests/hooks/run.sh — Layer 1: 훅 결정표 회귀 스위트
#
# JVM도 Gradle도 필요 없다. golden/ 의 canned TEST-*.xml 과 gradle 로그를 써서
# 각 훅을 stdin 주입으로 구동하고 종료 코드와 결과 상태를 단언한다.
#
#   ./tests/hooks/run.sh                  기본 셸(/bin/sh)로 실행
#   ./tests/hooks/run.sh --shell /bin/dash  POSIX 적합성 교차 검증
#   ./tests/hooks/run.sh --tier awk         JSON 폴백 단계 강제

set -u

TEST_SHELL=/bin/sh
FORCE_TIER=""
while [ $# -gt 0 ]; do
	case "$1" in
	--shell)
		TEST_SHELL=${2:-/bin/sh}
		shift 2
		;;
	--tier)
		FORCE_TIER=${2:-}
		shift 2
		;;
	*) shift ;;
	esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
HOOKS=$ROOT/.claude/hooks
GOLDEN=$HERE/golden

# shellcheck source=../lib/assert.sh
. "$ROOT/tests/lib/assert.sh"

[ -n "$FORCE_TIER" ] && export TDD_JSON_TIER="$FORCE_TIER"
printf 'shell=%s  tier=%s\n' "$TEST_SHELL" "${FORCE_TIER:-auto}"

SANDBOX=""
cleanup() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 샌드박스 + 드라이버
# ---------------------------------------------------------------------------

# new_sandbox [scopeMode] [enabled]
new_sandbox() {
	[ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
	SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/tddh.XXXXXX")
	mkdir -p "$SANDBOX/.claude" \
		"$SANDBOX/core/src/main/java/com/acme/user" \
		"$SANDBOX/core/src/main/kotlin/com/acme/order" \
		"$SANDBOX/core/src/main/resources" \
		"$SANDBOX/core/src/test/java/com/acme/user" \
		"$SANDBOX/core/build/test-results/test" \
		"$SANDBOX/other/src/main/java/org/far"
	: >"$SANDBOX/build.gradle.kts"
	: >"$SANDBOX/core/src/main/resources/application.yml"
	printf '{\n  "enabled": %s,\n  "scopeMode": "%s",\n  "postEditNormalize": false,\n  "formatOnStop": false,\n  "allowPatterns": ["**/*Application.java", "**/*Application.kt"]\n}\n' \
		"${2:-true}" "${1:-warn}" >"$SANDBOX/.claude/tdd-guard.json"
	export CLAUDE_PROJECT_DIR="$SANDBOX"
	# run-marker를 과거로 밀어 두어 golden XML이 항상 "신선"하게 보이도록 한다
	mkdir -p "$SANDBOX/.tdd-state"
	printf '*\n' >"$SANDBOX/.tdd-state/.gitignore"
	: >"$SANDBOX/.tdd-state/run-marker"
	touch -t 200001010000 "$SANDBOX/.tdd-state/run-marker"
}

# force_state key=value ...
force_state() {
	{
		for kv in "$@"; do printf '%s\n' "$kv"; done
		printf 'version=1\n'
	} >"$SANDBOX/.tdd-state/state"
}

state_of() { sed -n 's/^state=//p' "$SANDBOX/.tdd-state/state" 2>/dev/null | head -1; }
field_of() { sed -n "s/^$1=//p" "$SANDBOX/.tdd-state/state" 2>/dev/null | head -1; }

# guard <abs-path> [tool] → 종료 코드를 출력
guard() {
	printf '{"session_id":"t","cwd":"%s","tool_name":"%s","tool_input":{"file_path":"%s"}}' \
		"$SANDBOX" "${2:-Write}" "$1" |
		"$TEST_SHELL" "$HOOKS/tdd-guard-pre-edit.sh" >"$SANDBOX/.out" 2>"$SANDBOX/.err"
	printf '%s' "$?"
}

guard_stdout() { cat "$SANDBOX/.out" 2>/dev/null; }
guard_stderr() { cat "$SANDBOX/.err" 2>/dev/null; }

# guard_raw <json-payload> — 임의 페이로드로 가드를 돌리고 종료 코드만 출력.
# ( `cmd || printf $?` 는 성공(0) 시 아무것도 안 찍는다. 반드시 `;` 로 잇는다. )
guard_raw() {
	printf '%s' "$1" | "$TEST_SHELL" "$HOOKS/tdd-guard-pre-edit.sh" >/dev/null 2>&1
	printf '%s' $?
}

mark() {
	printf '{"session_id":"t","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' \
		"$SANDBOX" "$1" | "$TEST_SHELL" "$HOOKS/tdd-mark-edit.sh" >/dev/null 2>&1
}

# put_xml <golden-file>  — 결과 XML을 심고 mtime을 지금으로
put_xml() {
	cp "$GOLDEN/$1" "$SANDBOX/core/build/test-results/test/TEST-suite.xml"
	touch "$SANDBOX/core/build/test-results/test/TEST-suite.xml"
}
clear_xml() { rm -f "$SANDBOX/core/build/test-results/test/"*.xml 2>/dev/null; }

# record <log-golden-or-literal>  — gradle 실행을 재현
record() {
	if [ -f "$GOLDEN/$1" ]; then _rl=$(cat "$GOLDEN/$1"); else _rl=$1; fi
	# 로그를 JSON 문자열로 안전하게 인코딩
	_enc=$(printf '%s' "$_rl" | awk '
        BEGIN { printf "\"" }
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "%s\\n", $0 }
        END { printf "\"" }')
	printf '{"session_id":"t","cwd":"%s","tool_name":"Bash","tool_input":{"command":"./gradlew :core:test"},"tool_response":%s}' \
		"$SANDBOX" "$_enc" |
		"$TEST_SHELL" "$HOOKS/tdd-record-run.sh" >"$SANDBOX/.out" 2>&1
}

stop() {
	printf '{"session_id":"t","cwd":"%s","stop_hook_active":%s}' "$SANDBOX" "${1:-false}" |
		"$TEST_SHELL" "$HOOKS/tdd-verify-stop.sh" >"$SANDBOX/.out" 2>"$SANDBOX/.err"
	printf '%s' "$?"
}

MAIN_JAVA=core/src/main/java/com/acme/user/UserService.java
MAIN_KT=core/src/main/kotlin/com/acme/order/OrderService.kt
TEST_JAVA=core/src/test/java/com/acme/user/UserServiceTest.java

# ---------------------------------------------------------------------------
group "가드 스코프 — 프로덕션 JVM 소스만 지킨다"
# ---------------------------------------------------------------------------
new_sandbox
assert_eq "IDLE에서 src/main/**.java 는 차단" 2 "$(guard "$SANDBOX/$MAIN_JAVA")"
assert_eq "IDLE에서 src/main/**.kt 는 차단" 2 "$(guard "$SANDBOX/$MAIN_KT")"
assert_eq "src/test 는 항상 허용" 0 "$(guard "$SANDBOX/$TEST_JAVA")"
assert_eq "build.gradle.kts 는 항상 허용" 0 "$(guard "$SANDBOX/build.gradle.kts")"
assert_eq "src/main/resources 는 항상 허용" 0 "$(guard "$SANDBOX/core/src/main/resources/application.yml")"
assert_eq ".claude 내부는 항상 허용" 0 "$(guard "$SANDBOX/.claude/tdd-guard.json")"
assert_eq "allowPatterns(*Application.java)는 허용" 0 \
	"$(guard "$SANDBOX/core/src/main/java/com/acme/user/DemoApplication.java")"
assert_eq "프로젝트 밖 절대경로는 관여하지 않음" 0 "$(guard "/etc/hosts")"
assert_eq "file_path 없으면 fail open" 0 \
	"$(guard_raw "$(printf '{"session_id":"t","cwd":"%s","tool_name":"Write","tool_input":{}}' "$SANDBOX")")"

# ---------------------------------------------------------------------------
group "상태 게이트 — 페이즈는 하드 차단"
# ---------------------------------------------------------------------------
new_sandbox
force_state state=IDLE
assert_eq "IDLE → 차단" 2 "$(guard "$SANDBOX/$MAIN_JAVA")"
assert_contains "IDLE 거부 메시지가 다음 행동을 지명" "실패 테스트를 먼저 작성" "$(guard_stderr)"

force_state state=RED_PENDING
assert_eq "RED_PENDING → 차단" 2 "$(guard "$SANDBOX/$MAIN_JAVA")"
assert_contains "RED_PENDING 거부는 실행 명령을 지명" "gradlew" "$(guard_stderr)"

force_state state=RED_VERIFIED failing_symbols=UserService
assert_eq "RED_VERIFIED → 허용" 0 "$(guard "$SANDBOX/$MAIN_JAVA")"

force_state state=GREEN_VERIFIED
assert_eq "GREEN_VERIFIED → 차단" 2 "$(guard "$SANDBOX/$MAIN_JAVA")"
assert_contains "GREEN 거부는 enter-refactor를 안내" "enter-refactor" "$(guard_stderr)"

force_state state=REFACTOR refactor_deadline=99999999999 refactor_edits_used=0 refactor_edit_budget=40
assert_eq "REFACTOR(예산 내) → 허용" 0 "$(guard "$SANDBOX/$MAIN_JAVA")"

force_state state=REFACTOR refactor_deadline=1 refactor_edits_used=0 refactor_edit_budget=40
assert_eq "REFACTOR(기한 만료) → 차단" 2 "$(guard "$SANDBOX/$MAIN_JAVA")"

force_state state=REFACTOR refactor_deadline=99999999999 refactor_edits_used=40 refactor_edit_budget=40
assert_eq "REFACTOR(예산 소진) → 차단" 2 "$(guard "$SANDBOX/$MAIN_JAVA")"
assert_contains "예산 소진 메시지는 쪼개기를 권함" "쪼개세요" "$(guard_stderr)"

# ---------------------------------------------------------------------------
group "실행 분류 — Gradle이 진실이다"
# ---------------------------------------------------------------------------
new_sandbox
force_state state=RED_PENDING
put_xml assertion-red.xml
record "BUILD FAILED"
assert_eq "assertion-red → RED_VERIFIED" RED_VERIFIED "$(state_of)"
assert_eq "red_kind=assertion" assertion "$(field_of red_kind)"
assert_eq "실패 스위트 기록" com.acme.user.UserServiceTest "$(field_of failing_suites)"
assert_contains "스택트레이스 타입 수집" UserService "$(field_of mentioned_types)"
assert_not_contains "JDK 프레임은 제외" Method "$(field_of mentioned_types)"

new_sandbox
force_state state=RED_PENDING
clear_xml
record compile-red-javac.log
assert_eq "javac compile-red → RED_VERIFIED" RED_VERIFIED "$(state_of)"
assert_eq "red_kind=compile" compile "$(field_of red_kind)"
assert_contains "미해결 심볼 추출(javac)" UserService "$(field_of failing_symbols)"
assert_contains "예외 타입도 심볼로 추출" UserNotFoundException "$(field_of failing_symbols)"
assert_contains "로그에서 테스트 스위트 복원" com.acme.user.UserServiceTest "$(field_of failing_suites)"

new_sandbox
force_state state=RED_PENDING
clear_xml
record compile-red-kotlinc.log
assert_eq "kotlinc compile-red → RED_VERIFIED" RED_VERIFIED "$(state_of)"
assert_contains "미해결 심볼 추출(kotlinc)" OrderService "$(field_of failing_symbols)"

new_sandbox
force_state state=RED_VERIFIED red_kind=assertion failing_suites=com.acme.user.UserServiceTest
put_xml green.xml
record "BUILD SUCCESSFUL"
assert_eq "green → GREEN_VERIFIED" GREEN_VERIFIED "$(state_of)"
assert_eq "그린이면 실패 정보 초기화" "" "$(field_of failing_suites)"
assert_eq "그린이면 편집 카운터 초기화" 0 "$(field_of main_edits_since_green)"

new_sandbox
force_state state=RED_PENDING
put_xml spring-context-error.xml
record "BUILD FAILED"
# @WebMvcTest 가 컨텍스트를 못 띄우는 것은 대개 "협력자를 아직 안 만들었다"는
# 정당한 RED 다. XML 의 errors 로 잡히므로 특별 취급이 필요 없다.
assert_eq "Spring 컨텍스트 로드 실패 → RED_VERIFIED" RED_VERIFIED "$(state_of)"
assert_eq "errors 도 RED 로 센다" assertion "$(field_of red_kind)"
assert_contains "누락된 협력자를 스코프 신호로 수집" OrderService "$(field_of mentioned_types)"
assert_not_contains "Spring 내부 프레임은 제외" ConstructorResolver "$(field_of mentioned_types)"

new_sandbox
force_state state=RED_VERIFIED
clear_xml
record main-compile-broken.log
assert_eq "main-compile-broken → 전이 없음" RED_VERIFIED "$(state_of)"
assert_contains "프로덕션 컴파일 실패를 명시" "RED가 아닙니다" "$(cat "$SANDBOX/.out")"

new_sandbox
force_state state=GREEN_VERIFIED
clear_xml
record infra-red.log
assert_eq "infra-red → 전이 없음" GREEN_VERIFIED "$(state_of)"

new_sandbox
force_state state=GREEN_VERIFIED
clear_xml
record up-to-date.log
assert_eq "UP-TO-DATE → 전이 없음" GREEN_VERIFIED "$(state_of)"
assert_contains "cleanTest 안내" cleanTest "$(cat "$SANDBOX/.out")"

new_sandbox
force_state state=RED_PENDING
put_xml green.xml
touch -t 200001010000 "$SANDBOX/core/build/test-results/test/TEST-suite.xml"
touch "$SANDBOX/.tdd-state/run-marker"
record "BUILD SUCCESSFUL"
assert_eq "오래된 XML은 무시(mtime 게이트)" RED_PENDING "$(state_of)"

new_sandbox
force_state state=IDLE
put_xml green.xml
printf '{"session_id":"t","cwd":"%s","tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":"x"}' \
	"$SANDBOX" | "$TEST_SHELL" "$HOOKS/tdd-record-run.sh" >/dev/null 2>&1
assert_eq "비-Gradle 명령은 무시" IDLE "$(state_of)"

# ---------------------------------------------------------------------------
group "스코프 매칭 — 기본은 소프트 경고"
# ---------------------------------------------------------------------------
new_sandbox
force_state state=RED_VERIFIED mentioned_types=UserService,UserRepository
assert_eq "스택트레이스 타입 일치 → 조용히 허용" 0 "$(guard "$SANDBOX/$MAIN_JAVA")"
assert_eq "일치 시 경고 없음" "" "$(guard_stdout)"

force_state state=RED_VERIFIED failing_symbols=UserService
assert_eq "미해결 심볼 일치 → 허용" 0 "$(guard "$SANDBOX/$MAIN_JAVA")"

force_state state=RED_VERIFIED failing_suites=com.acme.user.UserServiceTest
assert_eq "UserServiceTest → UserService 접두 일치" 0 "$(guard "$SANDBOX/$MAIN_JAVA")"
mkdir -p "$SANDBOX/core/src/main/java/com/acme/user"
assert_eq "UserServiceTest → UserServiceImpl 도 일치" 0 \
	"$(guard "$SANDBOX/core/src/main/java/com/acme/user/UserServiceImpl.java")"

force_state state=RED_VERIFIED failing_suites=com.acme.user.SomethingElseTest
assert_eq "같은 패키지면 일치(규칙 d)" 0 "$(guard "$SANDBOX/$MAIN_JAVA")"

force_state state=RED_VERIFIED failing_suites=com.acme.user.UserServiceTest
assert_eq "무관 파일 warn 모드 → 허용" 0 "$(guard "$SANDBOX/other/src/main/java/org/far/Nothing.java")"
assert_contains "무관 파일은 경고를 남김" "직접 연결되지 않습니다" "$(guard_stdout)"

new_sandbox strict
force_state state=RED_VERIFIED failing_suites=com.acme.user.UserServiceTest
assert_eq "무관 파일 strict 모드 → 차단" 2 "$(guard "$SANDBOX/other/src/main/java/org/far/Nothing.java")"
assert_eq "strict 여도 연결된 파일은 허용" 0 "$(guard "$SANDBOX/$MAIN_JAVA")"

new_sandbox off
force_state state=RED_VERIFIED failing_suites=com.acme.user.UserServiceTest
assert_eq "scopeMode=off 는 조용히 허용" 0 "$(guard "$SANDBOX/other/src/main/java/org/far/Nothing.java")"
assert_eq "off 는 경고도 없음" "" "$(guard_stdout)"

# ---------------------------------------------------------------------------
group "탈출구 — 존재하되 모두 기록된다"
# ---------------------------------------------------------------------------
new_sandbox
force_state state=IDLE
assert_eq "TDD_GUARD=off 는 허용" 0 \
	"$(printf '{"session_id":"t","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' \
		"$SANDBOX" "$SANDBOX/$MAIN_JAVA" |
		TDD_GUARD=off "$TEST_SHELL" "$HOOKS/tdd-guard-pre-edit.sh" >/dev/null 2>&1
	printf '%s' $?)"
assert_contains "환경변수 우회가 감사 로그에 남음" bypass-env "$(cat "$SANDBOX/.tdd-state/events.log")"

: >"$SANDBOX/.tdd-state/BYPASS"
assert_eq "BYPASS 파일 → 허용" 0 "$(guard "$SANDBOX/$MAIN_JAVA")"
assert_contains "BYPASS 는 경고를 남김" "우회 중" "$(guard_stdout)"
rm -f "$SANDBOX/.tdd-state/BYPASS"

force_state state=IDLE scaffold_glob="*/payment/src/main/*" scaffold_expires=99999999999 scaffold_reason=new-module
mkdir -p "$SANDBOX/payment/src/main/java/com/acme/payment"
assert_eq "유효한 스캐폴딩 승인 → 허용" 0 \
	"$(guard "$SANDBOX/payment/src/main/java/com/acme/payment/PaymentService.java")"
assert_eq "승인 글롭 밖은 여전히 차단" 2 "$(guard "$SANDBOX/$MAIN_JAVA")"

force_state state=IDLE scaffold_glob="*/payment/src/main/*" scaffold_expires=1 scaffold_reason=new-module
assert_eq "만료된 스캐폴딩 승인 → 차단" 2 \
	"$(guard "$SANDBOX/payment/src/main/java/com/acme/payment/PaymentService.java")"

new_sandbox warn false
force_state state=IDLE
assert_eq "enabled=false 는 전부 허용" 0 "$(guard "$SANDBOX/$MAIN_JAVA")"

# ---------------------------------------------------------------------------
group "부기 — tdd-mark-edit"
# ---------------------------------------------------------------------------
new_sandbox
force_state state=IDLE
: >"$SANDBOX/$TEST_JAVA"
mark "$SANDBOX/$TEST_JAVA"
assert_eq "테스트 편집 → RED_PENDING" RED_PENDING "$(state_of)"

force_state state=GREEN_VERIFIED
mark "$SANDBOX/$TEST_JAVA"
assert_eq "GREEN에서 테스트 편집 → RED_PENDING" RED_PENDING "$(state_of)"

force_state state=RED_VERIFIED failing_symbols=UserService main_edits_since_green=0
mark "$SANDBOX/$TEST_JAVA"
assert_eq "RED_VERIFIED에서 테스트 편집은 상태 유지" RED_VERIFIED "$(state_of)"

force_state state=RED_VERIFIED main_edits_since_green=0
: >"$SANDBOX/$MAIN_JAVA"
mark "$SANDBOX/$MAIN_JAVA"
assert_eq "프로덕션 편집 → 카운터 증가" 1 "$(field_of main_edits_since_green)"

force_state state=REFACTOR refactor_edits_used=0 main_edits_since_green=0
mark "$SANDBOX/$MAIN_JAVA"
assert_eq "REFACTOR 중 편집 → 예산 소모" 1 "$(field_of refactor_edits_used)"

# ---------------------------------------------------------------------------
group "Stop 게이트 — 루프 캡 포함"
# ---------------------------------------------------------------------------
new_sandbox
force_state state=RED_VERIFIED failing_suites=com.acme.user.UserServiceTest stop_block_count=0
assert_eq "RED_VERIFIED 로 종료 시도 → 차단" 2 "$(stop)"
assert_eq "차단 후 카운터 증가" 1 "$(field_of stop_block_count)"

force_state state=RED_PENDING stop_block_count=0
assert_eq "RED_PENDING 로 종료 시도 → 차단" 2 "$(stop)"

force_state state=REFACTOR stop_block_count=0
assert_eq "REFACTOR 로 종료 시도 → 차단" 2 "$(stop)"

force_state state=GREEN_VERIFIED main_edits_since_green=3 stop_block_count=0
assert_eq "그린 이후 미검증 편집 → 차단" 2 "$(stop)"

force_state state=GREEN_VERIFIED main_edits_since_green=0 stop_block_count=0
assert_eq "검증된 그린 → 허용" 0 "$(stop)"

force_state state=IDLE stop_block_count=0
assert_eq "IDLE → 허용" 0 "$(stop)"

force_state state=RED_VERIFIED stop_block_count=2
assert_eq "루프 캡(2회) 도달 시 강제 허용" 0 "$(stop)"
assert_contains "캡 도달을 명시" "강제로 종료를 허용" "$(cat "$SANDBOX/.out")"

force_state state=RED_VERIFIED stop_block_count=0
assert_eq "stop_hook_active=true 는 즉시 통과" 0 "$(stop true)"

# ---------------------------------------------------------------------------
group "견고성 — 깨져도 fail open"
# ---------------------------------------------------------------------------
new_sandbox
force_state state=IDLE
assert_eq "깨진 JSON → fail open" 0 "$(guard_raw '{"broken')"
assert_eq "빈 stdin → fail open" 0 "$(guard_raw '')"
assert_eq "cwd 없고 file_path만 있으면 fail open" 0 \
	"$(guard_raw '{"tool_name":"Write","tool_input":{"file_path":"/nowhere/src/main/java/X.java"}}')"

for tier in jq python3 awk; do
	command -v "$tier" >/dev/null 2>&1 || [ "$tier" = awk ] || continue
	new_sandbox
	force_state state=IDLE
	_rc=$(printf '{"session_id":"t","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' \
		"$SANDBOX" "$SANDBOX/$MAIN_JAVA" |
		TDD_JSON_TIER="$tier" "$TEST_SHELL" "$HOOKS/tdd-guard-pre-edit.sh" >/dev/null 2>&1
	printf '%s' $?)
	assert_eq "JSON 파서 $tier 로도 동일하게 차단" 2 "$_rc"
done

# ---------------------------------------------------------------------------
group "CLI — tdd-state.sh"
# ---------------------------------------------------------------------------
new_sandbox
force_state state=GREEN_VERIFIED main_edits_since_green=0 green_at="$(date -u +%s)"
"$TEST_SHELL" "$HOOKS/tdd-state.sh" enter-refactor >/dev/null 2>&1
assert_eq "신선한 그린에서 enter-refactor 성공" REFACTOR "$(state_of)"

force_state state=GREEN_VERIFIED main_edits_since_green=2 green_at="$(date -u +%s)"
"$TEST_SHELL" "$HOOKS/tdd-state.sh" enter-refactor >/dev/null 2>&1
assert_eq "미검증 편집이 있으면 enter-refactor 거부" GREEN_VERIFIED "$(state_of)"

force_state state=GREEN_VERIFIED main_edits_since_green=0 green_at=1
"$TEST_SHELL" "$HOOKS/tdd-state.sh" enter-refactor >/dev/null 2>&1
assert_eq "오래된 그린이면 enter-refactor 거부" GREEN_VERIFIED "$(state_of)"

force_state state=RED_VERIFIED
"$TEST_SHELL" "$HOOKS/tdd-state.sh" enter-refactor >/dev/null 2>&1
assert_eq "RED에서 enter-refactor 거부" RED_VERIFIED "$(state_of)"

force_state state=RED_VERIFIED
"$TEST_SHELL" "$HOOKS/tdd-state.sh" reset >/dev/null 2>&1
assert_eq "reset → IDLE" IDLE "$(state_of)"

"$TEST_SHELL" "$HOOKS/tdd-state.sh" grant-scaffold --glob '*/pay/*' --reason 'new module' --ttl 5m >/dev/null 2>&1
assert_eq "grant-scaffold 가 글롭 기록" '*/pay/*' "$(field_of scaffold_glob)"

assert_contains "status 가 상태를 출력" "TDD 상태" "$("$TEST_SHELL" "$HOOKS/tdd-state.sh" status 2>&1)"
assert_contains "explain 이 상태 머신을 설명" "RED_VERIFIED" "$("$TEST_SHELL" "$HOOKS/tdd-state.sh" explain 2>&1)"

# ---------------------------------------------------------------------------
group "세션 시작"
# ---------------------------------------------------------------------------
new_sandbox
force_state state=RED_VERIFIED failing_suites=com.acme.user.UserServiceTest
_out=$(printf '{"session_id":"t","cwd":"%s","source":"startup"}' "$SANDBOX" |
	"$TEST_SHELL" "$HOOKS/tdd-session-start.sh" 2>&1)
assert_contains "중단된 사이클을 세션에 알림" "RED_VERIFIED" "$_out"
assert_eq "세션 시작은 상태를 바꾸지 않음" RED_VERIFIED "$(state_of)"

force_state state=RED_VERIFIED
touch -t 200001010000 "$SANDBOX/.tdd-state/state"
printf '{"session_id":"t","cwd":"%s","source":"startup"}' "$SANDBOX" |
	"$TEST_SHELL" "$HOOKS/tdd-session-start.sh" >/dev/null 2>&1
assert_eq "24시간 넘은 상태는 IDLE로 회수" IDLE "$(state_of)"

assert_summary
