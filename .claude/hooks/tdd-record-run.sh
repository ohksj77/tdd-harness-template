#!/bin/sh
# tdd-record-run.sh — PostToolUse / Bash
#
# 상태 머신의 심장. Gradle 실행 결과를 관찰해 상태를 전이시킨다.
#
# 왜 에이전트의 자기 보고를 쓰지 않는가:
# 스스로 상태를 선언할 수 있는 에이전트는 표류한다. TEST-*.xml은 Gradle이
# 썼고, mtime 게이트가 있어 오래된 초록을 재생할 수 없다.
#
# 종료 코드: 항상 0. 상태가 바뀌면 stdout에 한 줄 요약을 낸다.

set -u

HOOK_DIR=$(dirname "$0")
# shellcheck source=./_lib.sh
. "$HOOK_DIR/_lib.sh" || exit 0

hook_read_stdin
[ -n "$HOOK_STDIN" ] || exit 0

TDD_SESSION_ID=$(json_get session_id)
TDD_CMD=$(json_get tool_input.command)

# --- 1. Gradle 명령이 아니면 즉시 빠진다 (~2ms) ------------------------------
case "$TDD_CMD" in
*gradlew* | *'gradle '* | *'gradle	'*) : ;;
*) exit 0 ;;
esac

resolve_project_root || exit 0
ensure_state_dir || exit 0

TDD_STATE_BEFORE=$(current_state)

# --- 2. 실행 로그 적재 (compile-red 분류에 쓰인다) ---------------------------
TDD_RESPONSE=$(json_get tool_response)
if [ -n "$TDD_RESPONSE" ]; then
	printf '%s\n' "$TDD_RESPONSE" | tail -c 200000 >"$STATE_DIR/last-run.log.tmp" 2>/dev/null
	mv "$STATE_DIR/last-run.log.tmp" "$STATE_DIR/last-run.log" 2>/dev/null
fi
TDD_LOG=$STATE_DIR/last-run.log
[ -f "$TDD_LOG" ] || : >"$TDD_LOG"

# --- 3. 신선한 테스트 결과 XML 찾기 ------------------------------------------
# run-marker의 mtime이 "이전" 기준점이다. 없으면 아주 오래된 시각으로 만든다.
if [ ! -f "$STATE_DIR/run-marker" ]; then
	: >"$STATE_DIR/run-marker" 2>/dev/null
	touch -t 200001010000 "$STATE_DIR/run-marker" 2>/dev/null
fi

TDD_XML_LIST=$STATE_DIR/.fresh-xml.$$
find "$PROJECT_ROOT" -type f -name 'TEST-*.xml' -path '*/build/test-results/*' \
	-newer "$STATE_DIR/run-marker" >"$TDD_XML_LIST" 2>/dev/null

TDD_KIND=""
TDD_SUITES=""
TDD_SYMBOLS=""
TDD_TYPES=""

if [ -s "$TDD_XML_LIST" ]; then
	# --- 4. testsuite 속성 합산 ---------------------------------------------
	# Gradle/Ant 포맷은 속성이 한 줄에 있어 XML 파서가 필요 없다.
	# 파일 목록을 그대로 awk 인자로 넘기면 공백 있는 경로에서 깨진다.
	# 내용을 이어붙여 표준입력으로 준다 (스위트 경계는 필요 없다).
	cat_list() {
		while IFS= read -r _cl_f; do
			[ -f "$_cl_f" ] && cat "$_cl_f" 2>/dev/null
		done <"$TDD_XML_LIST"
	}

	TDD_TOTALS=$(
		cat_list | awk '
        /<testsuite[ \t]/ {
            line = $0
            t = 0; f = 0; e = 0; nm = ""
            if (match(line, /tests="[0-9]+"/))    t = substr(line, RSTART+7,  RLENGTH-8)
            if (match(line, /failures="[0-9]+"/)) f = substr(line, RSTART+10, RLENGTH-11)
            if (match(line, /errors="[0-9]+"/))   e = substr(line, RSTART+8,  RLENGTH-9)
            if (match(line, /[ \t]name="[^"]*"/)) nm = substr(line, RSTART+7, RLENGTH-8)
            T += t; F += f; E += e
            if (f + e > 0 && nm != "") {
                if (index("," suites ",", "," nm ",") == 0)
                    suites = suites (suites == "" ? "" : ",") nm
            }
        }
        END { printf "%d %d %d %s", T+0, F+0, E+0, suites }
        ' 2>/dev/null
	)
	TDD_T=$(printf '%s' "$TDD_TOTALS" | cut -d' ' -f1)
	TDD_F=$(printf '%s' "$TDD_TOTALS" | cut -d' ' -f2)
	TDD_E=$(printf '%s' "$TDD_TOTALS" | cut -d' ' -f3)
	TDD_SUITES=$(printf '%s' "$TDD_TOTALS" | cut -d' ' -f4-)
	: "${TDD_T:=0}" "${TDD_F:=0}" "${TDD_E:=0}"

	if [ "$((TDD_F + TDD_E))" -gt 0 ] 2>/dev/null; then
		TDD_KIND=assertion-red
		# 스택트레이스에 등장하는 프로젝트 타입 — 가장 강한 스코프 신호.
		# 실제 협력자를 지명하기 때문이다.
		TDD_TYPES=$(
			cat_list | awk '
            # 점으로 이어진 식별자를 모두 훑어, 마지막 대문자 시작 요소를 타입으로 본다.
            # 스택 프레임만 노리지 않는 이유:
            #   · `at com.acme.web.OrderController.&lt;init&gt;(` 처럼 메서드 이름이
            #     이스케이프되면 프레임 전용 정규식이 통째로 빗나간다
            #   · Spring 의 "No qualifying bean of type ..." 같은 메시지 안의 FQCN 이
            #     오히려 누락된 협력자를 가장 정확히 지목한다
            {
                line = $0
                while (match(line, /[a-z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_$]+)+/)) {
                    tok  = substr(line, RSTART, RLENGTH)
                    line = substr(line, RSTART + RLENGTH)

                    if (tok ~ /^(java|javax|jdk|sun|kotlin|kotlinx|scala)\./) continue
                    if (tok ~ /^com\.sun\./) continue
                    if (tok ~ /^org\.(junit|assertj|mockito|springframework|apache|gradle|opentest4j|hamcrest|slf4j|mockito)\./) continue
                    if (tok ~ /^(io\.mockk|io\.micrometer|net\.bytebuddy|worker\.org|jdk\.proxy)\./) continue

                    n = split(tok, parts, ".")
                    cls = ""
                    for (i = n; i >= 1; i--) {
                        if (parts[i] ~ /^[A-Z]/) { cls = parts[i]; break }
                    }
                    if (cls == "") continue
                    sub(/\$.*$/, "", cls)
                    if (cls == "" || length(cls) < 2) continue

                    if (index("," acc ",", "," cls ",") == 0) {
                        acc = acc (acc == "" ? "" : ",") cls
                        cnt++
                        if (cnt >= 40) exit
                    }
                }
            }
            END { printf "%s", acc }
            ' 2>/dev/null
		)
	elif [ "$TDD_T" -gt 0 ] 2>/dev/null; then
		TDD_KIND=green
	fi
fi
rm -f "$TDD_XML_LIST" 2>/dev/null

# --- 5. 신선한 XML이 없으면 로그로 분류 --------------------------------------
if [ -z "$TDD_KIND" ]; then
	if grep -qE 'compileTest(Java|Kotlin)[^ ]* FAILED|> Task :[^ ]*:compileTest[A-Za-z]+ FAILED' "$TDD_LOG" 2>/dev/null &&
		grep -qE 'cannot find symbol|Unresolved reference|package [A-Za-z0-9_.]+ does not exist|does not exist' "$TDD_LOG" 2>/dev/null; then
		# D2: 테스트 소스 컴파일 실패는 정당한 RED다.
		# JVM에서 첫 RED는 거의 항상 이 모양이고, 이때 Gradle은 테스트 XML을
		# 쓰지 않는다. 이 규칙이 없으면 첫 사이클에서 교착된다.
		TDD_KIND=compile-red
		TDD_SYMBOLS=$(
			awk '
            {
                if (match($0, /symbol:[ \t]+(class|variable|method|interface)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
                    tok = substr($0, RSTART, RLENGTH)
                    n = split(tok, p, /[ \t]+/)
                    cand = p[n]
                } else if (match($0, /Unresolved reference:?[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/)) {
                    tok = substr($0, RSTART, RLENGTH)
                    n = split(tok, p, /[ \t]+/)
                    cand = p[n]
                } else if (match($0, /package [A-Za-z0-9_.]+ does not exist/)) {
                    tok = substr($0, RSTART+8, RLENGTH-8)
                    sub(/ does not exist/, "", tok)
                    n = split(tok, p, ".")
                    cand = p[n]
                } else next
                if (cand == "" || cand !~ /^[A-Za-z_$]/) next
                if (index("," acc ",", "," cand ",") == 0) {
                    acc = acc (acc == "" ? "" : ",") cand
                    cnt++
                    if (cnt >= 40) exit
                }
            }
            END { printf "%s", acc }
            ' "$TDD_LOG" 2>/dev/null
		)
		TDD_SUITES=$(
			awk '
            {
                line = $0
                while (match(line, /src\/(test|integrationTest)\/(java|kotlin)\/[A-Za-z0-9_\/$]+\.(java|kt)/)) {
                    p = substr(line, RSTART, RLENGTH)
                    line = substr(line, RSTART+RLENGTH)
                    sub(/^src\/(test|integrationTest)\/(java|kotlin)\//, "", p)
                    sub(/\.(java|kt)$/, "", p)
                    gsub(/\//, ".", p)
                    if (index("," acc ",", "," p ",") == 0) {
                        acc = acc (acc == "" ? "" : ",") p
                        cnt++
                        if (cnt >= 20) exit
                    }
                }
            }
            END { printf "%s", acc }
            ' "$TDD_LOG" 2>/dev/null
		)
	elif grep -qE '> Task :[^ ]*:compile(Java|Kotlin)[A-Za-z]* FAILED|^Execution failed for task .:[^ ]*:compile(Java|Kotlin)' "$TDD_LOG" 2>/dev/null; then
		TDD_KIND=main-compile-broken
	elif grep -qE 'Could not resolve|Connection refused|Could not find or load|Could not connect to|Docker environment|Testcontainers|No such host is known|UnknownHostException' "$TDD_LOG" 2>/dev/null; then
		TDD_KIND=infra-red
	else
		TDD_KIND=no-fresh-results
	fi
fi

# --- 6. 전이 적용 ------------------------------------------------------------
TDD_STATE_AFTER=$TDD_STATE_BEFORE
TDD_NOTE=""

case "$TDD_KIND" in
assertion-red)
	TDD_STATE_AFTER=RED_VERIFIED
	state_set state=RED_VERIFIED red_kind=assertion \
		failing_suites="$TDD_SUITES" failing_symbols= mentioned_types="$TDD_TYPES" \
		last_run_at="$(iso_now)" stop_block_count=0 \
		refactor_deadline= refactor_edits_used=0
	TDD_NOTE="실패 스위트: ${TDD_SUITES:-?}"
	;;
compile-red)
	TDD_STATE_AFTER=RED_VERIFIED
	state_set state=RED_VERIFIED red_kind=compile \
		failing_suites="$TDD_SUITES" failing_symbols="$TDD_SYMBOLS" mentioned_types= \
		last_run_at="$(iso_now)" stop_block_count=0 \
		refactor_deadline= refactor_edits_used=0
	TDD_NOTE="미해결 심볼: ${TDD_SYMBOLS:-?}"
	;;
green)
	TDD_STATE_AFTER=GREEN_VERIFIED
	state_set state=GREEN_VERIFIED red_kind= \
		failing_suites= failing_symbols= mentioned_types= \
		green_at="$(epoch_now)" main_edits_since_green=0 \
		last_run_at="$(iso_now)" stop_block_count=0 \
		refactor_deadline= refactor_edits_used=0
	TDD_NOTE="테스트 ${TDD_T:-?}개 통과"
	;;
main-compile-broken)
	log_event run-main-compile-broken "$TDD_STATE_BEFORE" ""
	printf 'TDD: 프로덕션 소스가 컴파일되지 않습니다 (상태 전이 없음: %s).\n' "$TDD_STATE_BEFORE"
	printf '     이건 RED가 아닙니다. 마지막 편집을 되돌리거나 컴파일 오류부터 고치세요.\n'
	exit 0
	;;
infra-red)
	log_event run-infra-red "$TDD_STATE_BEFORE" ""
	printf 'TDD: 환경 문제로 보입니다 (의존성 해석·네트워크·Docker). 상태 전이 없음: %s.\n' "$TDD_STATE_BEFORE"
	exit 0
	;;
*)
	log_event run-no-fresh-results "$TDD_STATE_BEFORE" ""
	printf 'TDD: 새 테스트 결과가 없습니다 (UP-TO-DATE일 수 있음). 상태 전이 없음: %s.\n' "$TDD_STATE_BEFORE"
	printf '     강제 재실행: ./gradlew cleanTest test --tests %s\n' "'<YourTest>'"
	exit 0
	;;
esac

touch "$STATE_DIR/run-marker" 2>/dev/null
log_event run-"$TDD_KIND" "$TDD_STATE_BEFORE" "$TDD_STATE_AFTER"

if [ "$TDD_STATE_BEFORE" != "$TDD_STATE_AFTER" ]; then
	printf 'TDD: %s → %s (%s%s)\n' \
		"$TDD_STATE_BEFORE" "$TDD_STATE_AFTER" "$TDD_KIND" \
		"$([ -n "$TDD_NOTE" ] && printf ' · %s' "$TDD_NOTE")"
else
	printf 'TDD: %s 유지 (%s)\n' "$TDD_STATE_AFTER" "$TDD_KIND"
fi

exit 0
