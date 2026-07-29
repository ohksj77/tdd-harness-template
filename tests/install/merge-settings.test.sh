#!/bin/sh
# tests/install/merge-settings.test.sh
#
# settings.json 병합은 install.sh 에서 유일하게 사용자의 기존 파일을 고치는
# 지점이다. 여기서 실수하면 대상 프로젝트의 설정이 조용히 망가진다.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
# shellcheck source=../lib/assert.sh
. "$ROOT/tests/lib/assert.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tddm.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

new_target() {
	_t=$WORK/t$1
	rm -rf "$_t"
	mkdir -p "$_t/.claude"
	git -C "$_t" init -q 2>/dev/null
	: >"$_t/settings.gradle.kts"
	printf '%s' "$_t"
}

# ---------------------------------------------------------------------------
group "기존 settings.json 병합"
# ---------------------------------------------------------------------------
T=$(new_target 1)
cat >"$T/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "env": { "FOO": "bar" },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [ { "type": "command", "command": "/usr/local/bin/my-existing-hook.sh" } ]
      }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "/usr/local/bin/prompt-hook.sh" } ] }
    ]
  },
  "permissions": { "allow": ["Bash(ls:*)"] }
}
EOF
"$ROOT/install.sh" "$T" --copy >/dev/null 2>&1

S=$T/.claude/settings.json
assert_eq "무관한 최상위 키 보존 (model)" opus "$(jq -r '.model' "$S")"
assert_eq "중첩 객체 보존 (env.FOO)" bar "$(jq -r '.env.FOO' "$S")"
assert_eq "기존 PreToolUse 훅 생존" 1 \
	"$(jq '[.hooks.PreToolUse[].hooks[].command | select(test("my-existing-hook"))] | length' "$S")"
assert_eq "우리 가드 훅 추가됨" 1 \
	"$(jq '[.hooks.PreToolUse[].hooks[].command | select(test("tdd-guard-pre-edit"))] | length' "$S")"
assert_eq "무관한 다른 이벤트 훅 생존 (UserPromptSubmit)" 1 \
	"$(jq '.hooks.UserPromptSubmit | length' "$S")"
assert_eq "기존 permissions.allow 보존" 1 \
	"$(jq '[.permissions.allow[] | select(. == "Bash(ls:*)")] | length' "$S")"
assert_eq "우리 permissions 추가됨" 1 \
	"$(jq '[.permissions.allow[] | select(test("tdd-state.sh"))] | length' "$S")"
assert_ne "백업이 생성됨" "" "$(ls -1 "$T/.claude/"settings.json.bak.* 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
group "재실행 멱등성"
# ---------------------------------------------------------------------------
"$ROOT/install.sh" "$T" --copy >/dev/null 2>&1
"$ROOT/install.sh" "$T" --copy >/dev/null 2>&1
assert_eq "가드 훅이 중복되지 않음" 1 \
	"$(jq '[.hooks.PreToolUse[].hooks[].command | select(test("tdd-guard-pre-edit"))] | length' "$S")"
assert_eq "PostToolUse 항목도 중복 없음" 2 "$(jq '.hooks.PostToolUse | length' "$S")"
assert_eq "permissions 도 중복 없음" \
	"$(jq '.permissions.allow | length' "$S")" \
	"$(jq '.permissions.allow | unique | length' "$S")"
assert_eq "기존 훅은 여전히 살아 있음" 1 \
	"$(jq '[.hooks.PreToolUse[].hooks[].command | select(test("my-existing-hook"))] | length' "$S")"

# ---------------------------------------------------------------------------
group "settings.json 이 없던 경우"
# ---------------------------------------------------------------------------
T2=$(new_target 2)
"$ROOT/install.sh" "$T2" --copy >/dev/null 2>&1
assert_eq "스니펫이 그대로 설치됨" 1 \
	"$(jq '[.hooks.PreToolUse[].hooks[].command | select(test("tdd-guard-pre-edit"))] | length' "$T2/.claude/settings.json")"

# ---------------------------------------------------------------------------
group "--local 은 settings.local.json 을 쓴다"
# ---------------------------------------------------------------------------
T3=$(new_target 3)
"$ROOT/install.sh" "$T3" --copy --local >/dev/null 2>&1
assert_eq "settings.local.json 생성" 1 \
	"$(jq '[.hooks.PreToolUse[].hooks[].command | select(test("tdd-guard-pre-edit"))] | length' "$T3/.claude/settings.local.json")"
assert_eq "settings.json 은 건드리지 않음" "없음" \
	"$([ -f "$T3/.claude/settings.json" ] && printf '있음' || printf '없음')"

# ---------------------------------------------------------------------------
group "jq 가 없으면 텍스트 병합을 시도하지 않는다"
# ---------------------------------------------------------------------------
# 사용자의 settings.json 을 조용히 망가뜨리느니 거부하고 스니펫을 보여준다.
FAKEBIN=$WORK/nojq-bin
mkdir -p "$FAKEBIN"
for c in sh dash sed awk grep cat cp mv rm mkdir rmdir date git basename dirname find chmod ls touch head tail tr cut sort wc stat cmp printf sleep expr; do
	_p=$(command -v "$c" 2>/dev/null) && ln -sf "$_p" "$FAKEBIN/$c" 2>/dev/null
done

T4=$(new_target 4)
printf '{ "model": "opus" }\n' >"$T4/.claude/settings.json"
_before=$(cat "$T4/.claude/settings.json")
_out=$(PATH="$FAKEBIN" "$ROOT/install.sh" "$T4" --copy 2>&1)
_rc=$?
assert_ne "jq 부재 시 non-zero 로 종료" 0 "$_rc"
assert_contains "스니펫을 보여준다" "tdd-guard-pre-edit" "$_out"
assert_eq "기존 settings.json 을 건드리지 않았다" "$_before" "$(cat "$T4/.claude/settings.json")"

assert_summary
