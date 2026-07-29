#!/bin/sh
# tests/e2e/tdd-cycle.sh — Layer 3: 실제 Gradle 로 RED→GREEN→REFACTOR 전 사이클
#
# Layer 1 이 canned 데이터로 검증하는 것을 여기서는 진짜 Gradle 출력으로 확인한다.
# 특히 D2(테스트 컴파일 실패 = 정당한 RED)가 실제로 교착을 푸는지가 핵심이다.
#
#   ./tests/e2e/tdd-cycle.sh          :core (순수 Java) — 기본
#   ./tests/e2e/tdd-cycle.sh --web    :web (Spring Boot 슬라이스) — 느림
#   ./tests/e2e/tdd-cycle.sh --keep   작업 디렉토리 보존 (디버깅)
#
# Gradle wrapper 대신 시스템 gradle 을 쓴다. 훅의 명령 매처는 gradlew/gradle 을
# 모두 인식하며, 이 테스트의 관심사는 래퍼 프로비저닝이 아니라 훅↔Gradle 연동이다.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
# shellcheck source=../lib/assert.sh
. "$ROOT/tests/lib/assert.sh"

MODULE=core
KEEP=0
while [ $# -gt 0 ]; do
	case "$1" in
	--web) MODULE=web ;;
	--keep) KEEP=1 ;;
	esac
	shift
done

command -v gradle >/dev/null 2>&1 || {
	printf 'gradle 이 없습니다. brew install gradle 후 다시 시도하세요.\n' >&2
	exit 1
}
command -v java >/dev/null 2>&1 || {
	printf 'java 가 없습니다.\n' >&2
	exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tdde2e.XXXXXX")
cleanup() { [ "$KEEP" = "1" ] || rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

T=$WORK/sandbox
cp -R "$ROOT/fixtures/sandbox" "$T"
rm -f "$T/.gitignore"
git -C "$T" init -q
git -C "$T" config user.email t@example.com
git -C "$T" config user.name test
git -C "$T" add -A >/dev/null 2>&1
git -C "$T" commit -qm init >/dev/null 2>&1

printf '작업 디렉토리: %s  (모듈: :%s)\n' "$T" "$MODULE"

MAIN_DIR=$T/$MODULE/src/main/java/com/acme/$MODULE
TEST_DIR=$T/$MODULE/src/test/java/com/acme/$MODULE
mkdir -p "$MAIN_DIR" "$TEST_DIR"
CALC=$MAIN_DIR/Calculator.java
CALC_TEST=$TEST_DIR/CalculatorTest.java

H=$T/.claude/hooks
export CLAUDE_PROJECT_DIR="$T"

# ---------------------------------------------------------------------------
# 드라이버 — 실제 훅 스크립트를 실제 stdin 페이로드로 구동한다
# ---------------------------------------------------------------------------
guard() {
	printf '{"session_id":"e2e","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$T" "$1" |
		"$H/tdd-guard-pre-edit.sh" >"$WORK/.out" 2>"$WORK/.err"
	printf '%s' $?
}
mark() {
	printf '{"session_id":"e2e","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$T" "$1" |
		"$H/tdd-mark-edit.sh" >/dev/null 2>&1
}
stop() {
	printf '{"session_id":"e2e","cwd":"%s","stop_hook_active":false}' "$T" |
		"$H/tdd-verify-stop.sh" >"$WORK/.out" 2>"$WORK/.err"
	printf '%s' $?
}

# gradle_run <gradle args...> — 진짜로 돌리고 그 출력을 record 훅에 먹인다
gradle_run() {
	_cmd="gradle $*"
	(cd "$T" && gradle "$@" --console=plain --no-daemon) >"$WORK/gradle.log" 2>&1
	_exit=$?
	python3 - "$WORK/gradle.log" "$_cmd" "$T" <<'PY' >"$WORK/payload.json"
import json, sys
log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
print(json.dumps({
    "session_id": "e2e",
    "cwd": sys.argv[3],
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[2]},
    "tool_response": log,
}))
PY
	"$H/tdd-record-run.sh" <"$WORK/payload.json" >"$WORK/.record" 2>&1
	return $_exit
}

state_of() { sed -n 's/^state=//p' "$T/.tdd-state/state" 2>/dev/null | head -1; }
field_of() { sed -n "s/^$1=//p" "$T/.tdd-state/state" 2>/dev/null | head -1; }

# ---------------------------------------------------------------------------
group "1. 설치"
# ---------------------------------------------------------------------------
"$ROOT/install.sh" "$T" --copy >/dev/null 2>&1
# E2E 동안 Stop 훅이 JVM 포매터를 띄우지 않게 한다
printf '{ "enabled": true, "scopeMode": "warn", "formatOnStop": false, "postEditNormalize": false }\n' \
	>"$T/.claude/tdd-guard.json"

assert_eq "훅이 실행 가능" "있음" \
	"$([ -x "$H/tdd-guard-pre-edit.sh" ] && printf '있음' || printf '없음')"
assert_eq "settings.json 이 유효한 JSON" 0 \
	"$(jq empty "$T/.claude/settings.json" >/dev/null 2>&1
		printf '%s' $?)"
assert_eq ".tdd-state 가 자기 자신을 무시" "*" "$(cat "$T/.tdd-state/.gitignore")"

# ---------------------------------------------------------------------------
group "2~4. 사이클 없이는 프로덕션을 못 만진다"
# ---------------------------------------------------------------------------
assert_eq "IDLE 에서 Calculator.java 차단" 2 "$(guard "$CALC")"
assert_contains "거부 사유가 다음 행동을 지명" "실패 테스트를 먼저" "$(cat "$WORK/.err")"

cat >"$CALC_TEST" <<'EOF'
package com.acme.core;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class CalculatorTest {

    @Test
    void addsTwoNumbers() {
        assertThat(new Calculator().add(2, 3)).isEqualTo(5);
    }
}
EOF
mark "$CALC_TEST"
assert_eq "테스트 작성 → RED_PENDING" RED_PENDING "$(state_of)"
assert_eq "RED_PENDING 에서도 여전히 차단" 2 "$(guard "$CALC")"
assert_contains "아직 실행하지 않았음을 지적" "실행하지 않았습니다" "$(cat "$WORK/.err")"

# ---------------------------------------------------------------------------
group "5~6. D2 — 테스트 컴파일 실패는 정당한 RED"
# ---------------------------------------------------------------------------
printf '  (Gradle 최초 실행 — 의존성 내려받는 동안 시간이 걸립니다)\n'
gradle_run ":$MODULE:test" "--tests" "*CalculatorTest"

assert_eq "컴파일 실패가 RED_VERIFIED 로 분류됨" RED_VERIFIED "$(state_of)"
assert_eq "red_kind=compile" compile "$(field_of red_kind)"
assert_contains "미해결 심볼로 Calculator 를 잡아냄" Calculator "$(field_of failing_symbols)"
assert_contains "실패 스위트를 로그에서 복원" CalculatorTest "$(field_of failing_suites)"

# ★ 이 한 줄이 D2 의 존재 이유다. JVM 에서 첫 RED 는 XML 을 남기지 않는다.
assert_eq "★ RED_VERIFIED 에서 Calculator.java 허용 (D2 교착 해소)" 0 "$(guard "$CALC")"

# ---------------------------------------------------------------------------
group "7~8. GREEN"
# ---------------------------------------------------------------------------
cat >"$CALC" <<'EOF'
package com.acme.core;

public class Calculator {

    public int add(int a, int b) {
        return a + b;
    }
}
EOF
mark "$CALC"
gradle_run ":$MODULE:test" "--tests" "*CalculatorTest"

assert_eq "테스트 통과 → GREEN_VERIFIED" GREEN_VERIFIED "$(state_of)"
assert_eq "그린이면 실패 정보 초기화" "" "$(field_of failing_suites)"
assert_eq "그린이면 편집 카운터 0" 0 "$(field_of main_edits_since_green)"
assert_eq "GREEN 에서 프로덕션 편집 차단" 2 "$(guard "$CALC")"
assert_contains "enter-refactor 를 안내" "enter-refactor" "$(cat "$WORK/.err")"

# ---------------------------------------------------------------------------
group "9~12. REFACTOR 창"
# ---------------------------------------------------------------------------
"$H/tdd-state.sh" enter-refactor >/dev/null 2>&1
assert_eq "enter-refactor 성공" REFACTOR "$(state_of)"
assert_eq "REFACTOR 에서 프로덕션 편집 허용" 0 "$(guard "$CALC")"
assert_eq "REFACTOR 상태로는 종료 불가" 2 "$(stop)"
assert_contains "그린 재확인을 요구" "그린을 재확인" "$(cat "$WORK/.err")"

cat >"$CALC" <<'EOF'
package com.acme.core;

/** 동작은 그대로, 이름만 또렷하게. */
public class Calculator {

    public int add(int augend, int addend) {
        return augend + addend;
    }
}
EOF
mark "$CALC"
gradle_run ":$MODULE:test" "--tests" "*CalculatorTest"
assert_eq "리팩터링 후 그린 재확인 → GREEN_VERIFIED" GREEN_VERIFIED "$(state_of)"
assert_eq "검증된 그린이면 종료 허용" 0 "$(stop)"

# ---------------------------------------------------------------------------
group "13. assertion-red 경로 (XML 기반)"
# ---------------------------------------------------------------------------
cat >"$CALC_TEST" <<'EOF'
package com.acme.core;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class CalculatorTest {

    @Test
    void addsTwoNumbers() {
        assertThat(new Calculator().add(2, 3)).isEqualTo(5);
    }

    @Test
    void multipliesTwoNumbers() {
        assertThat(new Calculator().add(2, 3)).isEqualTo(6);
    }
}
EOF
mark "$CALC_TEST"
gradle_run ":$MODULE:test" "--tests" "*CalculatorTest"

assert_eq "어서션 실패 → RED_VERIFIED" RED_VERIFIED "$(state_of)"
assert_eq "red_kind=assertion" assertion "$(field_of red_kind)"
assert_contains "실패 스위트를 XML 에서 읽음" CalculatorTest "$(field_of failing_suites)"
assert_contains "스택트레이스에서 Calculator 수집" Calculator "$(field_of mentioned_types)"
assert_eq "RED 상태로는 종료 불가" 2 "$(stop)"

# ---------------------------------------------------------------------------
group "14. UP-TO-DATE 는 전이시키지 않는다"
# ---------------------------------------------------------------------------
# 실패한 테스트를 남겨 두면 Gradle 은 UP-TO-DATE 로 판정하지 않고 재실행한다.
# 진짜 UP-TO-DATE 를 만들려면 먼저 초록으로 되돌린 뒤 변경 없이 한 번 더 돌린다.
cat >"$CALC_TEST" <<'EOF'
package com.acme.core;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class CalculatorTest {

    @Test
    void addsTwoNumbers() {
        assertThat(new Calculator().add(2, 3)).isEqualTo(5);
    }
}
EOF
mark "$CALC_TEST"
gradle_run ":$MODULE:test" "--tests" "*CalculatorTest"
assert_eq "초록 복귀" GREEN_VERIFIED "$(state_of)"

gradle_run ":$MODULE:test" "--tests" "*CalculatorTest"
assert_eq "변경 없는 재실행은 상태를 바꾸지 않음" GREEN_VERIFIED "$(state_of)"
assert_contains "새 결과가 없음을 알리고 cleanTest 를 안내" "cleanTest" "$(cat "$WORK/.record")"

# ---------------------------------------------------------------------------
group "15. 제거하면 대상이 깨끗해진다"
# ---------------------------------------------------------------------------
rm -f "$CALC" "$CALC_TEST"
rm -rf "$T/$MODULE/build" "$T/build" "$T/.gradle"
"$ROOT/install.sh" "$T" --uninstall >/dev/null 2>&1
assert_eq "워킹트리 깨끗" "" "$(git -C "$T" status --porcelain)"

assert_summary
