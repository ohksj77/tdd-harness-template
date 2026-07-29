#!/bin/sh
# _lib.sh — TDD Harness 공용 라이브러리. 실행하지 않고 source 한다.
#
# 이식성 계약:
#   - POSIX sh. macOS /bin/bash 3.2.57(sh 모드)와 /bin/dash에서 동작해야 한다.
#   - 금지: [[ ]], =~, 배열, ${var,,}, local, echo -e, sed -i, grep -P,
#           find -printf, date -d, 프로세스 치환, $'...'
#   - set -e 금지. 헬퍼의 우발적 non-zero가 하드 차단이 되면 안 된다.
#     종료 코드는 각 훅 스크립트가 정확히 한 지점에서 명시적으로 결정한다.
#
# 이 파일의 어떤 함수도 프로세스를 종료시키지 않는다.

set -u

TDD_LIB_VERSION=1

# ---------------------------------------------------------------------------
# 기본 유틸
# ---------------------------------------------------------------------------

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch_now() { date -u +%s; }

# sanitize <value>
# 상태 파일에 쓸 값에서 위험 문자를 제거한다. 개행/등호가 파일 포맷을 깨뜨리고,
# 테스트 클래스명·스택트레이스는 신뢰할 수 없는 입력이므로 화이트리스트로 거른다.
sanitize() {
	printf '%s' "$1" | tr -d '\n\r' | sed 's/[^A-Za-z0-9._,:/*+-]//g'
}

# glob_match <path> <glob>
# sh의 case 글로빙을 쓴다. case의 '*'는 '/'도 매치하므로 '**'와 '*'는 동치다.
glob_match() {
	_gm_path=$1
	_gm_glob=$(printf '%s' "$2" | sed 's|\*\*|*|g')
	# shellcheck disable=SC2254
	case "$_gm_path" in
	$_gm_glob) return 0 ;;
	*) return 1 ;;
	esac
}

# in_csv <needle> <comma-separated-haystack>
in_csv() {
	_ic_needle=$1
	_ic_hay=,$2,
	case "$_ic_hay" in
	*,"$_ic_needle",*) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# JSON 추출 — 3단 폴백 (jq → python3 → awk)
#
# 파싱이 완전히 실패하면 빈 문자열을 돌려준다. 호출 측(가드)은 빈 값을 만나면
# fail open 한다. jq가 없다고 모든 편집을 하드 차단하는 가드는, 통과시키고
# 불평하는 가드보다 훨씬 나쁘다.
# ---------------------------------------------------------------------------

# 환경변수로 강제할 수 있다 (jq|python3|awk). 폴백 경로 테스트와 디버깅용.
TDD_JSON_TIER="${TDD_JSON_TIER:-}"

json_tier() {
	if [ -n "$TDD_JSON_TIER" ]; then
		printf '%s' "$TDD_JSON_TIER"
		return 0
	fi
	if command -v jq >/dev/null 2>&1; then
		TDD_JSON_TIER=jq
	elif command -v python3 >/dev/null 2>&1; then
		TDD_JSON_TIER=python3
	else
		TDD_JSON_TIER=awk
	fi
	printf '%s' "$TDD_JSON_TIER"
}

# HOOK_STDIN에 훅 입력 JSON을 담는다. 각 훅 스크립트가 시작 시 1회 호출한다.
HOOK_STDIN=""
hook_read_stdin() {
	HOOK_STDIN=$(cat 2>/dev/null || printf '')
}

# json_get <dotted.path>   예: json_get tool_input.file_path
# 값이 없거나 파싱 실패면 빈 문자열.
json_get() {
	_jg_path=$1
	[ -n "$HOOK_STDIN" ] || return 0

	case "$(json_tier)" in
	jq)
		printf '%s' "$HOOK_STDIN" |
			jq -r --arg p "$_jg_path" '
                ($p | split(".")) as $parts
                | reduce $parts[] as $k (.; if type == "object" then .[$k] else null end)
                | if . == null then "" elif type == "string" then . else tostring end
            ' 2>/dev/null
		;;
	python3)
		printf '%s' "$HOOK_STDIN" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
cur = d
for k in sys.argv[1].split("."):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(0)
if cur is None:
    sys.exit(0)
if isinstance(cur, str):
    sys.stdout.write(cur)
elif isinstance(cur, bool):
    sys.stdout.write("true" if cur else "false")
else:
    sys.stdout.write(json.dumps(cur))
' "$_jg_path" 2>/dev/null
		;;
	*)
		# 3단: 마지막 경로 요소를 키로 보고 문서 전체에서 찾는다.
		# 우리가 실제로 쓰는 키(file_path, command, cwd, session_id, tool_name,
		# notebook_path, stop_hook_active)는 충분히 고유하다.
		_jg_key=${_jg_path##*.}
		printf '%s' "$HOOK_STDIN" | awk -v key="$_jg_key" '
        BEGIN { RS="\0"; found=0 }
        {
            s = $0
            n = length(s)
            i = 1
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\"") {
                    # 문자열 토큰 읽기
                    tok = ""
                    i++
                    while (i <= n) {
                        ch = substr(s, i, 1)
                        if (ch == "\\") { tok = tok substr(s, i, 2); i += 2; continue }
                        if (ch == "\"") { i++; break }
                        tok = tok ch
                        i++
                    }
                    if (tok == key) {
                        # 이어지는 공백과 콜론
                        while (i <= n && substr(s, i, 1) ~ /[ \t\r\n]/) i++
                        if (substr(s, i, 1) != ":") continue
                        i++
                        while (i <= n && substr(s, i, 1) ~ /[ \t\r\n]/) i++
                        if (substr(s, i, 1) == "\"") {
                            val = ""
                            i++
                            while (i <= n) {
                                ch = substr(s, i, 1)
                                if (ch == "\\") {
                                    esc = substr(s, i+1, 1)
                                    if (esc == "n") val = val "\n"
                                    else if (esc == "t") val = val "\t"
                                    else if (esc == "r") val = val "\r"
                                    else if (esc == "u") { val = val "?"; i += 4 }
                                    else val = val esc
                                    i += 2
                                    continue
                                }
                                if (ch == "\"") { i++; break }
                                val = val ch
                                i++
                            }
                            printf "%s", val
                            found = 1
                            exit
                        } else {
                            val = ""
                            while (i <= n && substr(s, i, 1) !~ /[,}\]]/) { val = val substr(s, i, 1); i++ }
                            gsub(/[ \t\r\n]+$/, "", val)
                            printf "%s", val
                            found = 1
                            exit
                        }
                    }
                    continue
                }
                i++
            }
        }
        ' 2>/dev/null
		;;
	esac
}

# ---------------------------------------------------------------------------
# 프로젝트 루트 / 상태 디렉토리
#
# 해석 순서: $CLAUDE_PROJECT_DIR → 훅 입력의 cwd → git rev-parse --show-toplevel
# 어느 것도 그럴듯한 루트를 주지 못하면 빈 값 → 호출 측은 fail open.
# ---------------------------------------------------------------------------

PROJECT_ROOT=""
STATE_DIR=""

_looks_like_root() {
	[ -n "${1:-}" ] || return 1
	[ -d "$1" ] || return 1
	[ -e "$1/.git" ] || [ -d "$1/.claude" ] ||
		[ -f "$1/settings.gradle" ] || [ -f "$1/settings.gradle.kts" ] ||
		[ -f "$1/build.gradle" ] || [ -f "$1/build.gradle.kts" ] ||
		[ -f "$1/pom.xml" ]
}

resolve_project_root() {
	PROJECT_ROOT=""

	if _looks_like_root "${CLAUDE_PROJECT_DIR:-}"; then
		PROJECT_ROOT=$CLAUDE_PROJECT_DIR
	fi

	if [ -z "$PROJECT_ROOT" ]; then
		_rpr_cwd=$(json_get cwd)
		if _looks_like_root "$_rpr_cwd"; then
			PROJECT_ROOT=$_rpr_cwd
		fi
	fi

	if [ -z "$PROJECT_ROOT" ]; then
		_rpr_top=$(git rev-parse --show-toplevel 2>/dev/null || printf '')
		if _looks_like_root "$_rpr_top"; then
			PROJECT_ROOT=$_rpr_top
		fi
	fi

	# 후행 슬래시 제거
	case "$PROJECT_ROOT" in
	*/) PROJECT_ROOT=${PROJECT_ROOT%/} ;;
	esac

	if [ -n "$PROJECT_ROOT" ]; then
		STATE_DIR=$PROJECT_ROOT/.tdd-state
	else
		STATE_DIR=""
	fi
	[ -n "$PROJECT_ROOT" ]
}

# 상태 디렉토리를 만들고 self-ignoring .gitignore를 심는다.
# 대상 저장소의 .gitignore를 건드리지 않고 git에서 감추는 방법이다.
ensure_state_dir() {
	[ -n "$STATE_DIR" ] || return 1
	[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || return 1
	[ -f "$STATE_DIR/.gitignore" ] || printf '*\n' >"$STATE_DIR/.gitignore" 2>/dev/null
	[ -f "$STATE_DIR/run-marker" ] || : >"$STATE_DIR/run-marker" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# 락 — mkdir 기반 뮤텍스 (모든 POSIX 파일시스템에서 원자적)
# ---------------------------------------------------------------------------

TDD_LOCK_HELD=0
TDD_LOCK_STALE_SECS=60

state_lock() {
	[ -n "$STATE_DIR" ] || return 1
	_sl_tries=0
	while [ "$_sl_tries" -lt 20 ]; do
		if mkdir "$STATE_DIR/lock" 2>/dev/null; then
			TDD_LOCK_HELD=1
			return 0
		fi
		# stale 락 회수
		if [ -d "$STATE_DIR/lock" ]; then
			_sl_age=$(lock_age_secs)
			if [ "$_sl_age" -gt "$TDD_LOCK_STALE_SECS" ] 2>/dev/null; then
				rm -rf "$STATE_DIR/lock" 2>/dev/null
				continue
			fi
		fi
		sleep 0.1 2>/dev/null || sleep 1
		_sl_tries=$((_sl_tries + 1))
	done
	return 1
}

lock_age_secs() {
	_las_now=$(epoch_now)
	_las_mt=$(mtime_epoch "$STATE_DIR/lock")
	[ -n "$_las_mt" ] || {
		printf '0'
		return 0
	}
	printf '%s' "$((_las_now - _las_mt))"
}

# mtime_epoch <path> — BSD/GNU stat 양쪽 지원
mtime_epoch() {
	[ -e "$1" ] || return 0
	stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf ''
}

state_unlock() {
	[ "$TDD_LOCK_HELD" = "1" ] || return 0
	rm -rf "$STATE_DIR/lock" 2>/dev/null
	TDD_LOCK_HELD=0
	return 0
}

# ---------------------------------------------------------------------------
# 상태 파일 IO
#
# flat key=value. JSON이 아닌 이유: 우리 스크립트는 jq 없이도 읽고 써야 한다.
# 절대 source 하지 않는다 — 값의 일부는 신뢰할 수 없는 입력에서 온다.
# ---------------------------------------------------------------------------

STATE_KEYS='version state updated_at session_id red_kind last_run_at last_run_exit failing_suites failing_symbols mentioned_types green_at main_edits_since_green refactor_deadline refactor_edit_budget refactor_edits_used scaffold_glob scaffold_expires scaffold_reason stop_block_count'

state_get() {
	[ -n "$STATE_DIR" ] || return 0
	[ -f "$STATE_DIR/state" ] || return 0
	sed -n "s/^$1=//p" "$STATE_DIR/state" 2>/dev/null | head -1
}

# state_get_or <key> <default>
state_get_or() {
	_sgo_v=$(state_get "$1")
	if [ -n "$_sgo_v" ]; then printf '%s' "$_sgo_v"; else printf '%s' "$2"; fi
}

current_state() { state_get_or state IDLE; }

# state_set key=value [key=value ...]
# 전체 파일을 임시로 다시 쓰고 mv 한다(원자적). 락 아래에서 수행.
state_set() {
	[ -n "$STATE_DIR" ] || return 1
	ensure_state_dir || return 1
	state_lock || return 1

	_ss_tmp=$STATE_DIR/state.tmp.$$
	: >"$_ss_tmp" 2>/dev/null || {
		state_unlock
		return 1
	}

	# 새로 지정된 키를 개행 구분 목록으로 모은다
	_ss_new_keys=""
	for _ss_kv in "$@"; do
		_ss_k=${_ss_kv%%=*}
		_ss_new_keys="$_ss_new_keys $_ss_k"
	done

	# 기존 값 중 이번에 덮어쓰지 않는 것들을 보존
	if [ -f "$STATE_DIR/state" ]; then
		while IFS= read -r _ss_line; do
			case "$_ss_line" in
			'' | '#'*) continue ;;
			esac
			_ss_ek=${_ss_line%%=*}
			_ss_skip=0
			for _ss_nk in $_ss_new_keys; do
				[ "$_ss_ek" = "$_ss_nk" ] && _ss_skip=1
			done
			[ "$_ss_skip" = "1" ] || printf '%s\n' "$_ss_line" >>"$_ss_tmp"
		done <"$STATE_DIR/state"
	fi

	for _ss_kv in "$@"; do
		_ss_k=${_ss_kv%%=*}
		_ss_v=${_ss_kv#*=}
		printf '%s=%s\n' "$_ss_k" "$(sanitize "$_ss_v")" >>"$_ss_tmp"
	done

	# version/updated_at은 항상 최신으로
	grep -q '^version=' "$_ss_tmp" 2>/dev/null || printf 'version=%s\n' "$TDD_LIB_VERSION" >>"$_ss_tmp"
	sed '/^updated_at=/d' "$_ss_tmp" >"$_ss_tmp.2" 2>/dev/null && mv "$_ss_tmp.2" "$_ss_tmp" 2>/dev/null
	printf 'updated_at=%s\n' "$(iso_now)" >>"$_ss_tmp"

	mv "$_ss_tmp" "$STATE_DIR/state" 2>/dev/null
	_ss_rc=$?
	rm -f "$_ss_tmp" "$_ss_tmp.2" 2>/dev/null
	state_unlock
	return $_ss_rc
}

# 상태를 IDLE 초기값으로 되돌린다.
state_reset() {
	state_set \
		state=IDLE red_kind= failing_suites= failing_symbols= mentioned_types= \
		green_at= main_edits_since_green=0 refactor_deadline= refactor_edits_used=0 \
		scaffold_glob= scaffold_expires= scaffold_reason= stop_block_count= \
		last_run_at= last_run_exit=
}

# ---------------------------------------------------------------------------
# 감사 로그 — 모든 전이와 모든 우회가 여기 남는다.
# 탈출구가 비밀이 되지 않게 하는 장치다.
# ---------------------------------------------------------------------------

log_event() {
	[ -n "$STATE_DIR" ] || return 0
	ensure_state_dir || return 0
	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$(iso_now)" "${TDD_SESSION_ID:-?}" "${1:-}" "${2:-}" "${3:-}" \
		>>"$STATE_DIR/events.log" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# 설정 — .claude/tdd-guard.json
# ---------------------------------------------------------------------------

TDD_CFG_FILE=""
cfg_file() {
	if [ -z "$TDD_CFG_FILE" ] && [ -n "$PROJECT_ROOT" ]; then
		TDD_CFG_FILE=$PROJECT_ROOT/.claude/tdd-guard.json
	fi
	printf '%s' "$TDD_CFG_FILE"
}

# cfg_get <key> <default>
cfg_get() {
	_cg_f=$(cfg_file)
	if [ -z "$_cg_f" ] || [ ! -f "$_cg_f" ]; then
		printf '%s' "$2"
		return 0
	fi
	_cg_v=""
	if command -v jq >/dev/null 2>&1; then
		# `// empty` 를 쓰면 안 된다 — jq에서 false 는 falsy라 기본값으로
		# 되돌아가 버린다. enabled:false 가 무시되는 원인이었다.
		_cg_v=$(jq -r --arg k "$1" \
			'if has($k) and .[$k] != null then (.[$k] | if type=="string" then . else tostring end) else "" end' \
			"$_cg_f" 2>/dev/null)
	else
		_cg_v=$(sed -n "s/.*\"$1\"[ \t]*:[ \t]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$_cg_f" 2>/dev/null | head -1)
	fi
	if [ -n "$_cg_v" ]; then printf '%s' "$_cg_v"; else printf '%s' "$2"; fi
}

# cfg_list <key> — JSON 배열을 개행 구분으로
cfg_list() {
	_cl_f=$(cfg_file)
	[ -n "$_cl_f" ] && [ -f "$_cl_f" ] || return 0
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg k "$1" '.[$k][]? // empty' "$_cl_f" 2>/dev/null
	else
		# 배열 한 줄/여러 줄 모두에서 문자열 항목을 긁는다
		tr -d '\n' <"$_cl_f" 2>/dev/null |
			sed -n "s/.*\"$1\"[ \t]*:[ \t]*\[\([^]]*\)\].*/\1/p" |
			tr ',' '\n' | sed 's/^[ \t]*"//; s/"[ \t]*$//' | sed '/^[ \t]*$/d'
	fi
}

# ---------------------------------------------------------------------------
# 가드 스코프
#
# 프로덕션 JVM 소스 2개 소스셋만 지킨다. 이것이 오탐 대책의 1순위다 —
# 설정 파일·빌드 파일·리소스 예외를 "예외 목록"이 아니라 "스코프"로 처리하면
# 오탐의 대부분이 상태를 보기도 전에 구조적으로 사라진다.
# ---------------------------------------------------------------------------

is_guarded_path() {
	case "${1:-}" in
	*/src/main/java/*.java) return 0 ;;
	*/src/main/kotlin/*.kt) return 0 ;;
	*/src/main/kotlin/*.java) return 0 ;;
	*/src/main/java/*.kt) return 0 ;;
	*) return 1 ;;
	esac
}

is_test_path() {
	case "${1:-}" in
	*/src/test/*.java | */src/test/*.kt) return 0 ;;
	*/src/testFixtures/*.java | */src/testFixtures/*.kt) return 0 ;;
	*/src/integrationTest/*.java | */src/integrationTest/*.kt) return 0 ;;
	*) return 1 ;;
	esac
}

# 경로에서 자바 심플 네임과 패키지를 뽑는다.
# path_simple_name /a/b/src/main/java/com/acme/UserService.java  → UserService
path_simple_name() {
	_psn=${1##*/}
	_psn=${_psn%.java}
	_psn=${_psn%.kt}
	printf '%s' "$_psn"
}

# path_package /a/b/src/main/java/com/acme/user/UserService.java → com.acme.user
path_package() {
	_pp=$1
	case "$_pp" in
	*/src/main/java/*) _pp=${_pp#*/src/main/java/} ;;
	*/src/main/kotlin/*) _pp=${_pp#*/src/main/kotlin/} ;;
	*/src/test/java/*) _pp=${_pp#*/src/test/java/} ;;
	*/src/test/kotlin/*) _pp=${_pp#*/src/test/kotlin/} ;;
	*) printf '' && return 0 ;;
	esac
	_pp=${_pp%/*}
	case "$_pp" in
	*/*) printf '%s' "$_pp" | tr '/' '.' ;;
	*.java | *.kt) printf '' ;;
	*) printf '%s' "$_pp" ;;
	esac
}

# 테스트 클래스명에서 접미사를 떼어 프로덕션 후보 이름을 얻는다.
# UserServiceTest → UserService, UserServiceIT → UserService
strip_test_suffix() {
	_sts=$1
	_sts=${_sts%Test}
	_sts=${_sts%Tests}
	_sts=${_sts%IT}
	_sts=${_sts%Spec}
	_sts=${_sts%TestCase}
	printf '%s' "$_sts"
}
