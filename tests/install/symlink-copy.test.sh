#!/bin/sh
# tests/install/symlink-copy.test.sh
#
# 설치 모드(심링크/복사), dry-run, 충돌 감지, 그리고 가장 중요한
# "제거하면 대상이 원래대로 돌아오는가".

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
# shellcheck source=../lib/assert.sh
. "$ROOT/tests/lib/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tdds.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# 커밋까지 마친 깨끗한 대상 저장소를 만든다.
new_repo() {
	_t=$WORK/r$1
	rm -rf "$_t"
	mkdir -p "$_t/src/main/java/com/acme"
	: >"$_t/settings.gradle.kts"
	printf '# demo\n' >"$_t/README.md"
	git -C "$_t" init -q
	git -C "$_t" config user.email t@example.com
	git -C "$_t" config user.name test
	git -C "$_t" add -A >/dev/null 2>&1
	git -C "$_t" commit -qm init >/dev/null 2>&1
	printf '%s' "$_t"
}

# ---------------------------------------------------------------------------
group "--link — 항목별 심링크, .claude 통째 링크는 안 한다"
# ---------------------------------------------------------------------------
T=$(new_repo 1)
"$ROOT/install.sh" "$T" --link >/dev/null 2>&1
assert_eq ".claude 자체는 실제 디렉토리" "실제" \
	"$([ -L "$T/.claude" ] && printf '링크' || printf '실제')"
assert_eq "훅은 심링크" "링크" \
	"$([ -L "$T/.claude/hooks/tdd-guard-pre-edit.sh" ] && printf '링크' || printf '실제')"
assert_contains "심링크가 템플릿을 가리킴" "$ROOT" \
	"$(ls -l "$T/.claude/hooks/tdd-guard-pre-edit.sh" | sed 's/.*-> //')"
assert_eq "settings.json 은 링크가 아니라 실제 파일" "실제" \
	"$([ -L "$T/.claude/settings.json" ] && printf '링크' || printf '실제')"
assert_eq "tdd-guard.json 은 링크가 아니라 생성물" "실제" \
	"$([ -L "$T/.claude/tdd-guard.json" ] && printf '링크' || printf '실제')"
assert_eq "심링크 설치본도 실행 가능" 0 \
	"$(CLAUDE_PROJECT_DIR="$T" "$T/.claude/hooks/tdd-state.sh" status >/dev/null 2>&1
		printf '%s' $?)"

# ---------------------------------------------------------------------------
group "--copy — 자족적이어야 한다"
# ---------------------------------------------------------------------------
T2=$(new_repo 2)
"$ROOT/install.sh" "$T2" --copy >/dev/null 2>&1
assert_eq "훅이 실제 파일" "실제" \
	"$([ -L "$T2/.claude/hooks/tdd-guard-pre-edit.sh" ] && printf '링크' || printf '실제')"
assert_eq "훅에 실행 권한" "있음" \
	"$([ -x "$T2/.claude/hooks/tdd-guard-pre-edit.sh" ] && printf '있음' || printf '없음')"
assert_eq "_lib.sh 도 함께 복사됨 (형제 위치여야 source 된다)" "있음" \
	"$([ -f "$T2/.claude/hooks/_lib.sh" ] && printf '있음' || printf '없음')"
# 템플릿 경로를 전혀 참조하지 않고 동작하는지 확인
_rc=$(printf '{"session_id":"t","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s/src/main/java/com/acme/X.java"}}' \
	"$T2" "$T2" | CLAUDE_PROJECT_DIR="$T2" "$T2/.claude/hooks/tdd-guard-pre-edit.sh" >/dev/null 2>&1
printf '%s' $?)
assert_eq "복사본만으로 가드가 차단 판정" 2 "$_rc"

# ---------------------------------------------------------------------------
group "--dry-run 은 아무것도 바꾸지 않는다"
# ---------------------------------------------------------------------------
T3=$(new_repo 3)
_out=$("$ROOT/install.sh" "$T3" --copy --dry-run 2>&1)
assert_contains "수행할 동작을 출력" "dry-run" "$_out"
assert_eq "파일이 생기지 않음" "" "$(git -C "$T3" status --porcelain)"
assert_eq ".claude 가 만들어지지 않음" "없음" \
	"$([ -e "$T3/.claude/hooks" ] && printf '있음' || printf '없음')"

# ---------------------------------------------------------------------------
group "충돌 감지"
# ---------------------------------------------------------------------------
T4=$(new_repo 4)
mkdir -p "$T4/.claude/hooks"
printf 'echo mine\n' >"$T4/.claude/hooks/tdd-state.sh"
_out=$("$ROOT/install.sh" "$T4" --copy 2>&1)
_rc=$?
assert_ne "남의 파일과 충돌하면 중단" 0 "$_rc"
assert_contains "충돌 파일을 지목" "tdd-state.sh" "$_out"
assert_eq "사용자 파일은 그대로" "echo mine" "$(cat "$T4/.claude/hooks/tdd-state.sh")"

"$ROOT/install.sh" "$T4" --copy --force >/dev/null 2>&1
assert_ne "--force 는 백업을 남김" "" \
	"$(ls -1 "$T4/.claude/hooks/"tdd-state.sh.bak.* 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
group "--uninstall — 대상이 원래대로 돌아와야 한다"
# ---------------------------------------------------------------------------
T5=$(new_repo 5)
"$ROOT/install.sh" "$T5" --link >/dev/null 2>&1
assert_ne "설치 후에는 변경이 있다" "" "$(git -C "$T5" status --porcelain)"
"$ROOT/install.sh" "$T5" --uninstall >/dev/null 2>&1
assert_eq "제거 후 워킹트리가 깨끗하다" "" "$(git -C "$T5" status --porcelain)"
assert_eq ".tdd-state 도 사라짐" "없음" \
	"$([ -e "$T5/.tdd-state" ] && printf '있음' || printf '없음')"

# 기존 settings.json 이 있던 경우: 백업에서 복원되어야 한다
T6=$(new_repo 6)
mkdir -p "$T6/.claude"
printf '{ "model": "opus" }\n' >"$T6/.claude/settings.json"
git -C "$T6" add -A >/dev/null 2>&1
git -C "$T6" commit -qm settings >/dev/null 2>&1
"$ROOT/install.sh" "$T6" --copy >/dev/null 2>&1
"$ROOT/install.sh" "$T6" --uninstall >/dev/null 2>&1
assert_eq "settings.json 이 원본으로 복원됨" opus "$(jq -r '.model' "$T6/.claude/settings.json")"
assert_eq "가드 훅 배선이 사라짐" 0 \
	"$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(test("tdd-guard-pre-edit"))] | length' "$T6/.claude/settings.json")"

# CLAUDE.md: 기존 내용은 살리고 우리 블록만 뗀다
T7=$(new_repo 7)
printf '# 프로젝트\n\n기존 내용입니다.\n\n## 다른 섹션\n\n유지되어야 함.\n' >"$T7/CLAUDE.md"
git -C "$T7" add -A >/dev/null 2>&1
git -C "$T7" commit -qm claude >/dev/null 2>&1
"$ROOT/install.sh" "$T7" --copy >/dev/null 2>&1
assert_contains "포인터가 추가됨" "하네스: JVM 백엔드 TDD" "$(cat "$T7/CLAUDE.md")"
"$ROOT/install.sh" "$T7" --uninstall >/dev/null 2>&1
assert_not_contains "포인터가 제거됨" "하네스: JVM 백엔드 TDD" "$(cat "$T7/CLAUDE.md")"
assert_contains "기존 내용은 유지" "기존 내용입니다" "$(cat "$T7/CLAUDE.md")"
assert_contains "다른 섹션도 유지" "유지되어야 함" "$(cat "$T7/CLAUDE.md")"

# ---------------------------------------------------------------------------
group "--gitignore 는 명시할 때만 동작"
# ---------------------------------------------------------------------------
T8=$(new_repo 8)
"$ROOT/install.sh" "$T8" --copy >/dev/null 2>&1
assert_eq "기본값은 .gitignore 를 건드리지 않음" "없음" \
	"$([ -f "$T8/.gitignore" ] && printf '있음' || printf '없음')"
assert_eq ".tdd-state 는 자기 자신을 무시" "*" "$(cat "$T8/.tdd-state/.gitignore")"

T9=$(new_repo 9)
"$ROOT/install.sh" "$T9" --copy --gitignore >/dev/null 2>&1
assert_contains "--gitignore 면 _workspace/ 추가" "_workspace/" "$(cat "$T9/.gitignore")"

# ---------------------------------------------------------------------------
group "--scope-strict"
# ---------------------------------------------------------------------------
TA=$(new_repo 10)
"$ROOT/install.sh" "$TA" --copy --scope-strict >/dev/null 2>&1
assert_eq "tdd-guard.json 에 strict 기록" strict "$(jq -r '.scopeMode' "$TA/.claude/tdd-guard.json")"

assert_summary
