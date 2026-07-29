#!/bin/sh
# tests/harness/structure.test.sh — Layer 4: Harness 규약 자동 검증
#
# 하네스 규약은 문서에만 있으면 반드시 어긋난다. 여기서 기계로 강제한다.
# 출처: ~/.claude/plugins/marketplaces/harness-marketplace/skills/harness/

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/../.." && pwd -P)
# shellcheck source=../lib/assert.sh
. "$ROOT/tests/lib/assert.sh"

AGENTS=$ROOT/.claude/agents
SKILLS=$ROOT/.claude/skills

# frontmatter_keys <file> — --- 블록의 최상위 키를 개행 구분으로
frontmatter_keys() {
	awk 'NR==1 && $0=="---" { inside=1; next }
         inside && $0=="---" { exit }
         inside && /^[A-Za-z_-]+:/ { sub(/:.*/, ""); print }' "$1"
}

frontmatter_value() {
	awk -v k="$2" 'NR==1 && $0=="---" { inside=1; next }
         inside && $0=="---" { exit }
         inside && index($0, k ":") == 1 { sub(/^[^:]*:[ ]*/, ""); print; exit }' "$1"
}

has_section() { grep -qF "$2" "$1"; }

# ---------------------------------------------------------------------------
group "디렉토리 구조"
# ---------------------------------------------------------------------------
assert_eq ".claude/agents 존재" "있음" "$([ -d "$AGENTS" ] && printf '있음' || printf '없음')"
assert_eq ".claude/skills 존재" "있음" "$([ -d "$SKILLS" ] && printf '있음' || printf '없음')"
# Harness 체크리스트: "프로젝트/.claude/commands/ — 아무것도 생성하지 않음"
assert_eq ".claude/commands 는 만들지 않는다" "없음" \
	"$([ -e "$ROOT/.claude/commands" ] && printf '있음' || printf '없음')"

ORCH_COUNT=$(find "$SKILLS" -maxdepth 1 -type d -name '*-orchestrator' | wc -l | tr -d ' ')
assert_eq "오케스트레이터 스킬은 정확히 1개" 1 "$ORCH_COUNT"

# ---------------------------------------------------------------------------
group "에이전트 정의 — frontmatter 는 name + description 만"
# ---------------------------------------------------------------------------
for f in "$AGENTS"/*.md; do
	[ -f "$f" ] || continue
	base=$(basename "$f" .md)

	keys=$(frontmatter_keys "$f" | sort | tr '\n' ',' | sed 's/,$//')
	assert_eq "$base: frontmatter 키" "description,name" "$keys"

	assert_eq "$base: name 이 파일명과 일치" "$base" "$(frontmatter_value "$f" name)"

	desc=$(frontmatter_value "$f" description)
	assert_ne "$base: description 비어 있지 않음" "" "$desc"
	if [ "${#desc}" -ge 40 ]; then
		pass "$base: description 이 충분히 구체적"
	else
		fail "$base: description 이 너무 짧음" "40자 이상" "${#desc}자"
	fi
done

# ---------------------------------------------------------------------------
group "에이전트 정의 — 필수 섹션"
# ---------------------------------------------------------------------------
for f in "$AGENTS"/*.md; do
	[ -f "$f" ] || continue
	base=$(basename "$f" .md)
	for s in '## 핵심 역할' '## 작업 원칙' '## 입력/출력 프로토콜' '## 에러 핸들링' '## 협업'; do
		if has_section "$f" "$s"; then
			pass "$base: $s"
		else
			fail "$base: $s 누락"
		fi
	done
done

# 팀 모드로 참여하는 에이전트는 팀 통신 프로토콜을 가져야 한다.
# tdd-refactorer 는 의도적으로 서브 전용이므로 없는 것이 맞다.
for a in tdd-contract-designer tdd-test-author tdd-implementer tdd-boundary-inspector; do
	f=$AGENTS/$a.md
	if has_section "$f" '## 팀 통신 프로토콜'; then
		pass "$a: 팀 통신 프로토콜 있음 (팀 모드 참여)"
	else
		fail "$a: 팀 통신 프로토콜 누락"
	fi
done
if has_section "$AGENTS/tdd-refactorer.md" '## 팀 통신 프로토콜'; then
	fail "tdd-refactorer: 팀 통신 프로토콜이 있으면 안 된다 (서브 전용)"
else
	pass "tdd-refactorer: 팀 통신 프로토콜 없음 (서브 전용, 의도된 설계)"
fi

# ---------------------------------------------------------------------------
group "스킬 — frontmatter, 길이, 후속 키워드"
# ---------------------------------------------------------------------------
for d in "$SKILLS"/*/; do
	[ -d "$d" ] || continue
	name=$(basename "$d")
	sk=$d/SKILL.md

	if [ ! -f "$sk" ]; then
		fail "$name: SKILL.md 없음"
		continue
	fi

	keys=$(frontmatter_keys "$sk" | sort | tr '\n' ',' | sed 's/,$//')
	assert_eq "$name: frontmatter 키" "description,name" "$keys"
	assert_eq "$name: name 이 디렉토리명과 일치" "$name" "$(frontmatter_value "$sk" name)"

	lines=$(wc -l <"$sk" | tr -d ' ')
	if [ "$lines" -le 500 ]; then
		pass "$name: SKILL.md ${lines}줄 (≤500)"
	else
		fail "$name: SKILL.md 가 너무 김" "≤500줄" "${lines}줄"
	fi

	# description 은 "pushy" 해야 하고 후속 키워드를 담아야 한다.
	# 없으면 첫 실행 후 하네스가 사실상 죽은 코드가 된다.
	desc=$(frontmatter_value "$sk" description)
	found=0
	for kw in 재실행 '다시' 수정 보완 후속 개선; do
		case "$desc" in *"$kw"*) found=1 ;; esac
	done
	if [ "$found" = "1" ]; then
		pass "$name: description 에 후속 키워드 있음"
	else
		fail "$name: description 에 후속 키워드 없음 (재실행/다시/수정/보완/개선)"
	fi
done

# ---------------------------------------------------------------------------
group "references — 300줄 이상이면 ToC 필수"
# ---------------------------------------------------------------------------
for f in $(find "$SKILLS" -name '*.md' -path '*/references/*' | sort); do
	rel=${f#"$SKILLS"/}
	lines=$(wc -l <"$f" | tr -d ' ')
	if [ "$lines" -ge 300 ]; then
		if grep -qE '^## (목차|Table of Contents)' "$f"; then
			pass "$rel: ${lines}줄, ToC 있음"
		else
			fail "$rel: ${lines}줄인데 ToC 없음"
		fi
	else
		pass "$rel: ${lines}줄 (ToC 불필요)"
	fi
done

# ---------------------------------------------------------------------------
group "스킬 내부 링크가 실제 파일을 가리키는가"
# ---------------------------------------------------------------------------
BROKEN=0
for sk in "$SKILLS"/*/SKILL.md; do
	[ -f "$sk" ] || continue
	d=$(dirname "$sk")
	name=$(basename "$d")
	for target in $(grep -oE '\]\((references|scripts)/[A-Za-z0-9_.-]+\)' "$sk" |
		sed 's/^](//; s/)$//'); do
		if [ ! -f "$d/$target" ]; then
			fail "$name: 링크가 가리키는 파일 없음 → $target"
			BROKEN=1
		fi
	done
done
[ "$BROKEN" = "0" ] && pass "모든 스킬 내부 링크가 유효함"

# ---------------------------------------------------------------------------
group "오케스트레이터 필수 요소"
# ---------------------------------------------------------------------------
ORCH=$SKILLS/jvm-tdd-orchestrator/SKILL.md
for s in '## 실행 모드: 하이브리드' '### Phase 0: 컨텍스트 확인' \
	'## 데이터 흐름' '## 에러 핸들링' '## 테스트 시나리오'; do
	if has_section "$ORCH" "$s"; then
		pass "오케스트레이터: $s"
	else
		fail "오케스트레이터: $s 누락"
	fi
done

if grep -q '정상 흐름' "$ORCH" && grep -q '에러 흐름' "$ORCH"; then
	pass "오케스트레이터: 정상 흐름 + 에러 흐름 시나리오 존재"
else
	fail "오케스트레이터: 테스트 시나리오에 정상/에러 흐름이 모두 필요"
fi

if grep -q 'model: "opus"' "$ORCH"; then
	pass "오케스트레이터: model 을 런타임 인자로 명시"
else
	fail "오케스트레이터: 모든 Agent/TeamCreate 호출에 model: \"opus\" 를 명시해야 함"
fi

# 에이전트 표에 실제 존재하는 에이전트만 등장하는가
for a in tdd-contract-designer tdd-test-author tdd-implementer tdd-refactorer tdd-boundary-inspector; do
	if grep -q "$a" "$ORCH"; then
		pass "오케스트레이터가 $a 를 배치함"
	else
		fail "오케스트레이터에 $a 가 없음"
	fi
done

# ---------------------------------------------------------------------------
group "CLAUDE.md — 포인터 + 변경 이력만"
# ---------------------------------------------------------------------------
CM=$ROOT/CLAUDE.md
if [ -f "$CM" ]; then
	assert_contains "하네스 헤딩 존재" "## 하네스:" "$(cat "$CM")"
	assert_contains "트리거 규칙 존재" "**트리거:**" "$(cat "$CM")"
	assert_contains "변경 이력 존재" "**변경 이력:**" "$(cat "$CM")"
	# 에이전트 목록·디렉토리 트리를 넣지 않는다
	if grep -qE '^\| *tdd-(test-author|implementer|refactorer) ' "$CM"; then
		fail "CLAUDE.md 에 에이전트 목록이 있음 (포인터만 담아야 함)"
	else
		pass "CLAUDE.md 에 에이전트 목록 없음"
	fi
else
	fail "CLAUDE.md 없음"
fi

assert_summary
