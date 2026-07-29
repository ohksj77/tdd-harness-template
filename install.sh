#!/bin/sh
# install.sh — JVM 백엔드 TDD 하네스를 대상 프로젝트에 설치한다.
#
#   ./install.sh [TARGET_DIR] [옵션]
#
# 기본은 심링크 설치다. 템플릿을 고치면 모든 프로젝트에 즉시 반영된다.
# --copy 는 벤더링이며 템플릿이 사라져도 동작한다.
#
# 절대 하지 않는 것:
#   · .claude 디렉토리를 통째로 심링크 (대상의 기존 .claude 를 덮어쓴다)
#   · jq 없이 settings.json 을 텍스트로 병합 (조용히 망가뜨리느니 거부한다)
#   · 대상의 .gitignore 를 말없이 수정 (--gitignore 로 명시해야 한다)

set -u

TEMPLATE_DIR=$(cd "$(dirname "$0")" && pwd -P)
TARGET=""
MODE=link
SETTINGS_BASENAME=settings.json
DO_GITIGNORE=0
SCOPE_MODE=warn
DO_CLAUDE_MD=1
DRY_RUN=0
FORCE=0
ACTION=install

MANIFEST_REL=.claude/.tdd-harness-manifest
VERSION_REL=.claude/.tdd-harness-version

# ---------------------------------------------------------------------------
usage() {
	cat <<'EOF'
사용법: ./install.sh [TARGET_DIR] [옵션]

  TARGET_DIR          설치 대상 (기본: 현재 디렉토리)

  --link              심링크 설치 (기본). 템플릿 수정이 즉시 반영된다.
  --copy              복사 설치. 자족적이며 템플릿 삭제 후에도 동작한다.
  --local             settings.json 대신 settings.local.json 에 기록
                      (공유 저장소에서 시험할 때 권장)
  --scope-strict      스코프 불일치도 하드 차단 (기본은 경고)
  --gitignore         대상 .gitignore 에 _workspace/ 추가 (기본 off)
  --no-claude-md      CLAUDE.md 포인터를 넣지 않음
  --dry-run           수행할 동작만 출력하고 아무것도 바꾸지 않음
  --force             충돌하는 기존 파일을 백업 후 덮어씀
  --uninstall         설치한 것을 제거하고 settings.json 백업을 복원
  --doctor            기존 설치를 진단 (문제가 있으면 non-zero)
  --version           템플릿 버전과 git SHA 출력
  -h, --help          이 도움말
EOF
}

log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() {
	printf 'install: %s\n' "$*" >&2
	exit 1
}

# act <설명> <명령...> — dry-run 이면 출력만
act() {
	_desc=$1
	shift
	if [ "$DRY_RUN" = "1" ]; then
		printf '  [dry-run] %s\n' "$_desc"
		return 0
	fi
	"$@"
}

abspath_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
	--link) MODE=link ;;
	--copy) MODE=copy ;;
	--local) SETTINGS_BASENAME=settings.local.json ;;
	--scope-strict) SCOPE_MODE=strict ;;
	--gitignore) DO_GITIGNORE=1 ;;
	--no-claude-md) DO_CLAUDE_MD=0 ;;
	--dry-run) DRY_RUN=1 ;;
	--force) FORCE=1 ;;
	--uninstall) ACTION=uninstall ;;
	--doctor) ACTION=doctor ;;
	--version) ACTION=version ;;
	-h | --help)
		usage
		exit 0
		;;
	-*) die "알 수 없는 옵션: $1" ;;
	*) TARGET=$1 ;;
	esac
	shift
done

[ -n "$TARGET" ] || TARGET=$(pwd -P)
[ -d "$TARGET" ] || die "대상 디렉토리가 없습니다: $TARGET"
TARGET=$(abspath_dir "$TARGET")
[ "$TARGET" = "$TEMPLATE_DIR" ] && [ "$ACTION" = "install" ] &&
	die "템플릿 저장소 자기 자신에는 설치할 수 없습니다."

MANIFEST=$TARGET/$MANIFEST_REL
VERSION_FILE=$TARGET/$VERSION_REL

# ---------------------------------------------------------------------------
# 설치 항목 목록 — 상대 경로로 표준화한다.
# ---------------------------------------------------------------------------
list_items() {
	# agents: 파일 단위
	if [ -d "$TEMPLATE_DIR/.claude/agents" ]; then
		for f in "$TEMPLATE_DIR"/.claude/agents/*.md; do
			[ -f "$f" ] && printf 'file\t.claude/agents/%s\n' "$(basename "$f")"
		done
	fi
	# skills: 디렉토리 단위 (심링크 모드에서 디렉토리 하나로 묶는다)
	if [ -d "$TEMPLATE_DIR/.claude/skills" ]; then
		for d in "$TEMPLATE_DIR"/.claude/skills/*/; do
			[ -d "$d" ] || continue
			_n=$(basename "$d")
			printf 'dir\t.claude/skills/%s\n' "$_n"
		done
	fi
	# hooks: 파일 단위 (_lib.sh 포함 — 형제 위치에 있어야 source 가 된다)
	if [ -d "$TEMPLATE_DIR/.claude/hooks" ]; then
		for f in "$TEMPLATE_DIR"/.claude/hooks/*.sh; do
			[ -f "$f" ] && printf 'file\t.claude/hooks/%s\n' "$(basename "$f")"
		done
	fi
}

# ---------------------------------------------------------------------------
cmd_version() {
	_sha=$(git -C "$TEMPLATE_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
	printf 'jvm-tdd-harness (템플릿)\n'
	printf '  경로: %s\n' "$TEMPLATE_DIR"
	printf '  git : %s\n' "$_sha"
}

cmd_install() {
	log "TDD 하네스 설치"
	log "  템플릿 : $TEMPLATE_DIR"
	log "  대상   : $TARGET"
	log "  모드   : $MODE"
	log "  설정   : .claude/$SETTINGS_BASENAME"
	[ "$DRY_RUN" = "1" ] && log "  (dry-run — 아무것도 바꾸지 않습니다)"
	log ""

	if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; else HAVE_JQ=0; fi

	# --- 사전 점검: 우리가 만든 것이 아닌 충돌 파일 --------------------------
	_conflicts=""
	list_items | while IFS="$(printf '\t')" read -r _kind _rel; do
		_dst=$TARGET/$_rel
		if [ -e "$_dst" ] && [ ! -L "$_dst" ]; then
			if ! grep -qxF "$_rel" "$MANIFEST" 2>/dev/null; then
				printf '%s\n' "$_rel"
			fi
		fi
	done >"$TARGET/.tdd-conflicts.$$" 2>/dev/null
	_conflicts=$(cat "$TARGET/.tdd-conflicts.$$" 2>/dev/null)
	rm -f "$TARGET/.tdd-conflicts.$$"

	if [ -n "$_conflicts" ] && [ "$FORCE" != "1" ]; then
		warn "다음 파일이 이미 존재하며 이 하네스가 만든 것이 아닙니다:"
		printf '%s\n' "$_conflicts" | sed 's/^/  /' >&2
		die "--force 를 주면 백업 후 덮어씁니다."
	fi

	act "mkdir .claude/{agents,skills,hooks}" \
		mkdir -p "$TARGET/.claude/agents" "$TARGET/.claude/skills" "$TARGET/.claude/hooks"

	# --- 항목 설치 ----------------------------------------------------------
	_new_manifest=$TARGET/.tdd-manifest.$$
	[ "$DRY_RUN" = "1" ] || : >"$_new_manifest"

	list_items | while IFS="$(printf '\t')" read -r _kind _rel; do
		_src=$TEMPLATE_DIR/$_rel
		_dst=$TARGET/$_rel

		if [ -e "$_dst" ] || [ -L "$_dst" ]; then
			if [ -L "$_dst" ]; then
				act "rm 기존 심링크 $_rel" rm -f "$_dst"
			elif [ "$FORCE" = "1" ]; then
				act "backup $_rel" mv "$_dst" "$_dst.bak.$(date -u +%s)"
			else
				act "rm 기존 설치본 $_rel" rm -rf "$_dst"
			fi
		fi

		act "mkdir -p $(dirname "$_rel")" mkdir -p "$(dirname "$_dst")"

		if [ "$MODE" = "link" ]; then
			act "ln -s $_rel" ln -s "$_src" "$_dst"
		else
			if [ "$_kind" = "dir" ]; then
				act "cp -R $_rel" cp -R "$_src" "$_dst"
			else
				act "cp $_rel" cp "$_src" "$_dst"
			fi
			case "$_rel" in
			*.sh) act "chmod 755 $_rel" chmod 755 "$_dst" ;;
			*/hooks/*) act "chmod 755 $_rel" chmod 755 "$_dst" ;;
			esac
		fi
		[ "$DRY_RUN" = "1" ] || printf '%s\n' "$_rel" >>"$_new_manifest"
	done

	# 복사 모드에서 스킬 안의 스크립트에도 실행 권한을 준다
	if [ "$MODE" = "copy" ] && [ "$DRY_RUN" != "1" ]; then
		find "$TARGET/.claude/skills" -name '*.sh' -exec chmod 755 {} \; 2>/dev/null
	fi

	# --- tdd-guard.json 은 생성한다 (링크하지 않는다) -----------------------
	# 프로젝트마다 scopeMode/allowPatterns 가 달라야 하므로, 심링크로 공유하면
	# 한 프로젝트의 설정이 다른 프로젝트로 새어 나간다.
	if [ ! -f "$TARGET/.claude/tdd-guard.json" ]; then
		if [ "$DRY_RUN" = "1" ]; then
			printf '  [dry-run] .claude/tdd-guard.json 생성 (scopeMode=%s)\n' "$SCOPE_MODE"
		else
			sed "s/\"scopeMode\": \"warn\"/\"scopeMode\": \"$SCOPE_MODE\"/" \
				"$TEMPLATE_DIR/assets/tdd-guard.default.json" >"$TARGET/.claude/tdd-guard.json"
			printf '%s\n' ".claude/tdd-guard.json" >>"$_new_manifest"
			log "  생성: .claude/tdd-guard.json (scopeMode=$SCOPE_MODE)"
		fi
	else
		log "  유지: .claude/tdd-guard.json (기존 설정 보존)"
	fi

	# --- .tdd-state/ ---------------------------------------------------------
	if [ "$DRY_RUN" = "1" ]; then
		printf '  [dry-run] .tdd-state/ 생성 + self-ignoring .gitignore\n'
	else
		mkdir -p "$TARGET/.tdd-state"
		printf '*\n' >"$TARGET/.tdd-state/.gitignore"
		: >"$TARGET/.tdd-state/run-marker"
		touch -t 200001010000 "$TARGET/.tdd-state/run-marker" 2>/dev/null
		log "  생성: .tdd-state/ (자기 자신을 무시하므로 대상 .gitignore 를 건드리지 않음)"
	fi

	# --- settings 병합 -------------------------------------------------------
	_settings=$TARGET/.claude/$SETTINGS_BASENAME
	_snippet=$TEMPLATE_DIR/assets/settings.snippet.json

	if [ ! -f "$_settings" ]; then
		if [ "$DRY_RUN" = "1" ]; then
			printf '  [dry-run] .claude/%s 신규 생성\n' "$SETTINGS_BASENAME"
		else
			cp "$_snippet" "$_settings"
			printf '%s\n' ".claude/$SETTINGS_BASENAME" >>"$_new_manifest"
			log "  생성: .claude/$SETTINGS_BASENAME"
		fi
	elif [ "$HAVE_JQ" != "1" ]; then
		warn ""
		warn "jq 가 없어 .claude/$SETTINGS_BASENAME 을 병합할 수 없습니다."
		warn "조용히 망가뜨리느니 건드리지 않습니다. 아래 블록을 직접 병합하세요:"
		warn ""
		cat "$_snippet" >&2
		[ "$DRY_RUN" = "1" ] || rm -f "$_new_manifest"
		exit 1
	else
		_bak=$_settings.bak.$(date -u +%s)
		if [ "$DRY_RUN" = "1" ]; then
			printf '  [dry-run] .claude/%s 병합 (백업 후)\n' "$SETTINGS_BASENAME"
		else
			cp "$_settings" "$_bak"
			_tmp=$_settings.tmp.$$
			if jq -s -f "$TEMPLATE_DIR/assets/merge-settings.jq" "$_settings" "$_snippet" >"$_tmp" 2>/dev/null &&
				jq empty "$_tmp" 2>/dev/null && [ -s "$_tmp" ]; then
				mv "$_tmp" "$_settings"
				# 매니페스트에 반드시 넣는다. 빠지면 --uninstall 이 백업 복원을
				# 건너뛰어 대상에 훅 배선이 남는다.
				grep -qxF ".claude/$SETTINGS_BASENAME" "$_new_manifest" 2>/dev/null ||
					printf '%s\n' ".claude/$SETTINGS_BASENAME" >>"$_new_manifest"
				log "  병합: .claude/$SETTINGS_BASENAME (백업: $(basename "$_bak"))"
			else
				rm -f "$_tmp"
				cp "$_bak" "$_settings"
				die "settings 병합에 실패했습니다. 원본을 복원했습니다."
			fi
		fi
	fi

	# --- CLAUDE.md 포인터 ----------------------------------------------------
	if [ "$DO_CLAUDE_MD" = "1" ]; then
		_cmd_md=$TARGET/CLAUDE.md
		if grep -q '^## 하네스: JVM 백엔드 TDD' "$_cmd_md" 2>/dev/null; then
			log "  유지: CLAUDE.md 포인터 (이미 있음)"
		elif [ "$DRY_RUN" = "1" ]; then
			printf '  [dry-run] CLAUDE.md 에 하네스 포인터 추가\n'
		else
			[ -f "$_cmd_md" ] && printf '\n' >>"$_cmd_md"
			sed "s/@INSTALL_DATE@/$(date -u +%Y-%m-%d)/" \
				"$TEMPLATE_DIR/assets/claude-md-pointer.md" >>"$_cmd_md"
			log "  추가: CLAUDE.md 하네스 포인터"
		fi
	fi

	# --- .gitignore (명시적 요청 시에만) --------------------------------------
	if [ "$DO_GITIGNORE" = "1" ]; then
		_gi=$TARGET/.gitignore
		if grep -qxF '_workspace/' "$_gi" 2>/dev/null; then
			log "  유지: .gitignore (_workspace/ 이미 있음)"
		elif [ "$DRY_RUN" = "1" ]; then
			printf '  [dry-run] .gitignore 에 _workspace/ 추가\n'
		else
			printf '\n# TDD 하네스 중간 산출물\n_workspace/\n_workspace_*/\n' >>"$_gi"
			log "  추가: .gitignore 에 _workspace/"
		fi
	fi

	# --- 매니페스트 ----------------------------------------------------------
	if [ "$DRY_RUN" != "1" ]; then
		mv "$_new_manifest" "$MANIFEST"
		{
			printf 'mode=%s\n' "$MODE"
			printf 'template=%s\n' "$TEMPLATE_DIR"
			printf 'sha=%s\n' "$(git -C "$TEMPLATE_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
			printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			printf 'settings=%s\n' "$SETTINGS_BASENAME"
		} >"$VERSION_FILE"
	fi

	log ""
	log "완료. 훅을 활성화하려면 Claude Code 세션을 다시 시작하세요"
	log "(프로젝트 settings.json 의 훅 변경은 실행 중 세션에 반영되지 않습니다)."
	log ""
	log "확인: cd $TARGET && ./.claude/hooks/tdd-state.sh status"
}

cmd_uninstall() {
	log "TDD 하네스 제거: $TARGET"
	[ -f "$MANIFEST" ] || die "매니페스트가 없습니다 ($MANIFEST_REL). 이 하네스가 설치된 대상이 아닙니다."

	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		_dst=$TARGET/$_rel
		case "$_rel" in
		*/settings.json | */settings.local.json)
			# settings 는 지우지 않는다 — 백업 복원으로 되돌린다
			_bak=$(ls -1t "$_dst".bak.* 2>/dev/null | head -1)
			if [ -n "$_bak" ]; then
				act "restore $_rel from $(basename "$_bak")" cp "$_bak" "$_dst"
			else
				act "rm $_rel (설치 시 신규 생성이었음)" rm -f "$_dst"
			fi
			;;
		*)
			act "rm $_rel" rm -rf "$_dst"
			;;
		esac
	done <"$MANIFEST"

	# CLAUDE.md 포인터 블록 제거: 헤딩부터 다음 '## ' 또는 EOF 까지.
	if [ -f "$TARGET/CLAUDE.md" ] && grep -q '^## 하네스: JVM 백엔드 TDD' "$TARGET/CLAUDE.md"; then
		if [ "$DRY_RUN" = "1" ]; then
			printf '  [dry-run] CLAUDE.md 포인터 블록 제거\n'
		else
			awk '
                /^## 하네스: JVM 백엔드 TDD/ { skip = 1; next }
                skip == 1 && /^## / { skip = 0 }
                skip == 0 { print }
            ' "$TARGET/CLAUDE.md" >"$TARGET/CLAUDE.md.tmp" &&
				mv "$TARGET/CLAUDE.md.tmp" "$TARGET/CLAUDE.md"
			# 포인터만 있던 파일이면 통째로 지운다 (공백 줄만 남는 경우 포함)
			if ! grep -q '[^[:space:]]' "$TARGET/CLAUDE.md" 2>/dev/null; then
				rm -f "$TARGET/CLAUDE.md"
			fi
			log "  제거: CLAUDE.md 하네스 포인터"
		fi
	fi

	act "rm .tdd-state/" rm -rf "$TARGET/.tdd-state"
	act "rm 매니페스트" rm -f "$MANIFEST" "$VERSION_FILE"

	# 비어 버린 디렉토리 정리
	for d in .claude/agents .claude/skills .claude/hooks .claude; do
		[ -d "$TARGET/$d" ] && act "rmdir $d (비어 있을 때만)" rmdir "$TARGET/$d" 2>/dev/null
	done

	log "제거 완료."
}

cmd_doctor() {
	_rc=0
	log "TDD 하네스 진단: $TARGET"
	log ""

	if [ -f "$VERSION_FILE" ]; then
		sed 's/^/  /' "$VERSION_FILE"
	else
		warn "  ✗ 설치 기록이 없습니다 ($VERSION_REL)"
		_rc=1
	fi
	log ""

	for h in tdd-guard-pre-edit tdd-record-run tdd-mark-edit tdd-verify-stop tdd-session-start tdd-state; do
		_p=$TARGET/.claude/hooks/$h.sh
		if [ ! -e "$_p" ]; then
			warn "  ✗ 없음: .claude/hooks/$h.sh"
			_rc=1
		elif [ ! -x "$_p" ]; then
			warn "  ✗ 실행 권한 없음: .claude/hooks/$h.sh"
			_rc=1
		elif [ -L "$_p" ] && [ ! -e "$_p" ]; then
			warn "  ✗ 끊어진 심링크: .claude/hooks/$h.sh"
			_rc=1
		else
			log "  ✓ .claude/hooks/$h.sh"
		fi
	done

	log ""
	if [ -f "$TARGET/.claude/tdd-guard.json" ]; then
		log "  ✓ tdd-guard.json (enabled=$(sed -n 's/.*"enabled"[ ]*:[ ]*\([a-z]*\).*/\1/p' "$TARGET/.claude/tdd-guard.json" | head -1))"
	else
		warn "  ✗ .claude/tdd-guard.json 없음"
		_rc=1
	fi

	_s=$TARGET/.claude/settings.json
	[ -f "$TARGET/.claude/settings.local.json" ] && _s=$TARGET/.claude/settings.local.json
	if [ -f "$_s" ]; then
		if command -v jq >/dev/null 2>&1; then
			if jq -e '.hooks.PreToolUse[]?.hooks[]?.command | select(test("tdd-guard-pre-edit"))' "$_s" >/dev/null 2>&1; then
				log "  ✓ $(basename "$_s") 에 가드 훅이 배선됨"
			else
				warn "  ✗ $(basename "$_s") 에 가드 훅이 없습니다"
				_rc=1
			fi
		else
			log "  · jq 없음 — settings 배선은 확인하지 못했습니다"
		fi
	else
		warn "  ✗ settings 파일 없음"
		_rc=1
	fi

	if [ -d "$TARGET/.tdd-state" ]; then
		log "  ✓ .tdd-state/ (상태: $(sed -n 's/^state=//p' "$TARGET/.tdd-state/state" 2>/dev/null | head -1 || printf 'IDLE'))"
		[ -f "$TARGET/.tdd-state/.gitignore" ] || {
			warn "  ✗ .tdd-state/.gitignore 없음 — git 에 노출됩니다"
			_rc=1
		}
	else
		warn "  ✗ .tdd-state/ 없음"
		_rc=1
	fi

	log ""
	log "  JSON 파서 단계: $(command -v jq >/dev/null 2>&1 && printf 'jq' || { command -v python3 >/dev/null 2>&1 && printf 'python3' || printf 'awk (최후 폴백)'; })"
	log "  셸            : $( ([ -x /bin/dash ] && printf 'dash 있음') || printf 'dash 없음')"

	if [ "$_rc" = "0" ]; then
		log ""
		log "이상 없음."
	fi
	return $_rc
}

case "$ACTION" in
install) cmd_install ;;
uninstall) cmd_uninstall ;;
doctor) cmd_doctor ;;
version) cmd_version ;;
esac
