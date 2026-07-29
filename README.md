# JVM 백엔드 TDD Harness

Java / Kotlin 백엔드 프로젝트에 복사하거나 심링크해서 쓰는 `.claude/` 템플릿.
RED→GREEN→REFACTOR 사이클을 **훅으로 실제 강제**한다.

에이전트가 "테스트 먼저 쓰겠습니다"라고 말하고 곧장 구현으로 가는 일이 없다.
상태는 에이전트의 선언이 아니라 **Gradle이 쓴 파일**로만 바뀐다.

```
IDLE ──src/test 편집──► RED_PENDING ──gradle: red──► RED_VERIFIED
                             │                            │
                             └──gradle: green───► GREEN_VERIFIED ◄──┐
                                                        │            │
                                         enter-refactor │       gradle: green
                                                        ▼       / 예산 소진
                                                    REFACTOR ────────┘

src/main/{java,kotlin} 편집이 허용되는 상태: RED_VERIFIED, REFACTOR
```

---

## 설치

```sh
git clone <이 저장소> ~/tools/claude-setting

cd ~/projects/my-spring-app
~/tools/claude-setting/install.sh            # 심링크 (기본)
~/tools/claude-setting/install.sh --copy     # 벤더링
```

**설치 후 Claude Code 세션을 다시 시작해야 훅이 활성화된다.**
프로젝트 `settings.json` 의 훅 변경은 실행 중인 세션에 반영되지 않는다.

```sh
~/tools/claude-setting/install.sh --doctor   # 설치 확인
```

### 주요 옵션

| 옵션 | 뜻 |
|---|---|
| `--link` (기본) | 항목별 심링크. 템플릿 수정이 모든 프로젝트에 즉시 반영 |
| `--copy` | 복사. 자족적이며 템플릿이 사라져도 동작 |
| `--local` | `settings.local.json` 에 기록 (공유 저장소에서 시험할 때) |
| `--scope-strict` | 스코프 불일치도 하드 차단 (기본은 경고) |
| `--gitignore` | 대상 `.gitignore` 에 `_workspace/` 추가 (기본 off) |
| `--dry-run` | 수행할 동작만 출력 |
| `--uninstall` | 설치한 것을 제거하고 `settings.json` 백업 복원 |

`.claude` 를 통째로 심링크하지 않는다. 항목별로 설치하므로 대상의 기존
`.claude/` 와 공존하고, `settings.json` 은 `jq` 로 **병합**된다 (재실행 멱등).
`jq` 가 없으면 텍스트 병합을 시도하지 않고 스니펫을 출력한 뒤 중단한다 —
남의 설정 파일을 조용히 망가뜨리는 것보다 수동 붙여넣기가 낫다.

---

## 쓰는 법

평소처럼 요청하면 된다.

```
결제 취소 API 만들어줘
이 NPE 재현 테스트부터 짜줘
UserService 리팩터링만 다시 해줘
```

`jvm-tdd-orchestrator` 스킬이 트리거되어 5개 에이전트를 사이클로 배열한다.

상태가 궁금하거나 막혔을 때:

```sh
./.claude/hooks/tdd-state.sh status     # 현재 상태와 근거
./.claude/hooks/tdd-state.sh explain    # 상태 머신 + 막혔을 때 할 일
./.claude/hooks/tdd-state.sh events 20  # 감사 로그
```

---

## 구성

### 에이전트 5종 (`.claude/agents/`)

| 에이전트 | 타입 | 담당 |
|---|---|---|
| `tdd-contract-designer` | `Plan` | 기능을 테스트 가능한 계약으로 분해 |
| `tdd-test-author` | 커스텀 | 실패하는 테스트 작성 + RED 증명 |
| `tdd-implementer` | 커스텀 | RED를 통과시키는 최소 구현 |
| `tdd-refactorer` | 커스텀 | 그린 바 아래 동작 불변 개선 |
| `tdd-boundary-inspector` | `general-purpose` | 경계면 계약 불일치 검증 |

`tdd-contract-designer` 가 읽기 전용 `Plan` 인 것은 의도된 설계다.
가드가 가장 무력한 설계 단계에서 "설계하면서 코드도 좀 쓰지"를 구조적으로 막는다.

### 스킬 5종 (`.claude/skills/`)

| 스킬 | 내용 |
|---|---|
| `jvm-tdd-orchestrator` | 사이클 조율, 페이즈별 실행 모드, `_workspace/` 소유 |
| `jvm-test-authoring` | JUnit5 + AssertJ + Mockito, Java·Kotlin 공용 |
| `spring-test-slice-selection` | 가장 좁은 슬라이스 고르기, 컨텍스트 캐시 |
| `gradle-test-execution` | 좁게 실행, 실패 분류, 번들 스크립트 |
| `green-bar-refactoring` | 냄새별 동작, 되돌리기 규칙 |

### 훅 6종 (`.claude/hooks/`)

| 훅 | 이벤트 | 역할 |
|---|---|---|
| `tdd-guard-pre-edit.sh` | `PreToolUse` | 사이클 위반 시 exit 2로 **차단** |
| `tdd-record-run.sh` | `PostToolUse:Bash` | Gradle 결과를 관찰해 상태 전이 |
| `tdd-mark-edit.sh` | `PostToolUse:Edit` | 부기, 포매팅 대기열 |
| `tdd-verify-stop.sh` | `Stop` | 미완결 종료 차단, 일괄 포매팅 |
| `tdd-session-start.sh` | `SessionStart` | 중단된 사이클 알림, stale 회수 |
| `tdd-state.sh` | (CLI) | 상태 조회·명시적 전이 |

---

## 설계에서 알아 둘 것

### 컴파일 실패도 정당한 RED다

JVM에서 새 동작을 요구하는 첫 테스트는 대부분 아직 없는 타입을 참조한다.
이때 Gradle은 테스트를 실행하지 못해 **`TEST-*.xml` 을 쓰지 않는다.**
XML만 보는 도구는 "RED가 아니다"라고 판정하고, 첫 사이클에서 교착된다.

이 하네스는 `cannot find symbol` / `Unresolved reference` 를 정당한 RED로
인정한다. JS·Python용 TDD 가드를 그대로 옮기면 정확히 여기서 죽는다.

### 오탐이 진짜 실패 모드다

정당한 작업을 막는 가드는 하루 만에 꺼지고, 그러면 하네스는 없느니만 못하다.
대책은 순서대로:

1. **가드 스코프를 좁힌다** — `src/main/{java,kotlin}` 만 지킨다.
   빌드 스크립트·리소스·테스트·문서는 상태를 보기도 전에 통과한다
2. **파일 스코프 불일치는 기본 경고** — 페이즈 게이트만 하드 차단
3. **시간 제한 스캐폴딩 승인** — 신규 모듈 뼈대용
4. **`TDD_GUARD=off`** — 비상구

모든 우회는 `.tdd-state/events.log` 에 남고 Stop 훅이 누적 횟수를 보고한다.
탈출구가 비밀이 되지 않게 하려는 설계다.

### 상태는 워크트리별로 격리된다

상태는 `.claude/` 가 아니라 `<worktree-root>/.tdd-state/` 에 산다.
심링크 설치에서 여러 프로젝트가 상태 파일 하나를 공유하면 안 되기 때문이다.
`git worktree` 별 격리도 여기서 따라온다.

`.tdd-state/.gitignore` 에 `*` 한 줄이 들어가 **디렉토리가 자기 자신을 무시**하므로,
대상 저장소의 `.gitignore` 를 건드릴 필요가 없다.

### 훅에서 JVM을 띄우지 않는다

가드는 순수 POSIX sh 이고 50ms 미만을 목표로 한다. 편집마다 `spotlessApply` 를
돌리면 JVM 기동만 5~20초다. 실제 포매팅은 `Stop` 훅으로 일괄 미룬다.

### 에이전트 팀은 선택 사항이다

Phase 2(계약 설계)와 Phase 7(결함 해소)만 에이전트 팀을 쓰고,
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` 이 필요하다.

```sh
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

없으면 병렬 서브 에이전트로 폴백하고 **강등 사실을 사용자에게 알린다.**
RED→GREEN→REFACTOR 핵심 사이클은 원래 서브 에이전트 구간이므로
플래그 없이도 완전히 동작한다.

---

## 설정

`.claude/tdd-guard.json` (설치 시 생성, 프로젝트별로 다르다):

```json
{
  "enabled": true,
  "scopeMode": "warn",
  "postEditNormalize": true,
  "formatOnStop": true,
  "allowPatterns": ["**/*Application.java", "**/generated/**"]
}
```

| 키 | 값 | 기본 |
|---|---|---|
| `enabled` | bool | `true` |
| `scopeMode` | `warn` \| `strict` \| `off` | `warn` |
| `postEditNormalize` | bool | `true` |
| `formatOnStop` | bool | `true` |

`postEditNormalize` 는 편집 후 후행 공백만 정리한다. 그래도 Claude의 파일
스냅샷과 어긋나 다음 `Edit` 이 문자열 불일치로 실패하는 증상이 보이면
`false` 로 두라.

---

## 검증

```sh
./tests/run-all.sh          # Layer 1·2·4 — JVM 불필요, 수 초
./tests/run-all.sh --e2e    # + 실제 Gradle E2E — 수 분, JDK 필요
```

| 레이어 | 내용 | 개수 |
|---|---|---|
| 1 | 훅 결정표 (canned 데이터, `/bin/sh` + `dash` + awk 폴백 티어) | 98 |
| 2 | settings 병합, 심링크/복사/제거 | 48 |
| 3 | 실제 Gradle RED→GREEN→REFACTOR 전 사이클 | 33 |
| 4 | Harness 규약 구조 검증 | 104 |

Layer 3은 `fixtures/sandbox` 에서 진짜 Gradle을 돌려 D2(컴파일 실패 = RED)가
실제로 교착을 푸는지 확인한다.

`shellcheck` 이 설치되어 있으면 자동으로 함께 돈다 (없으면 건너뛴다).

---

## 알려진 제약

- **훅 활성화에 세션 재시작이 필요하다.** 프로젝트 `settings.json` 의 훅 변경은
  실행 중 세션에 반영되지 않는다. 설치 직후 한 번 재시작하라.
- **서브에이전트 훅 전파는 환경에 따라 다를 수 있다.** 오케스트레이터가
  페이즈 경계마다 `tdd-state.sh status` 를 직접 확인해 이중으로 보증하지만,
  설치 후 한 번 실제로 확인해 두면 좋다:

  ```
  서브에이전트에게 src/main 아래 아무 클래스나 만들어 보라고 시켜줘
  ```

  차단되면 전파가 되는 것이다. 되지 않으면 오케스트레이터의 상태 확인과
  Stop 훅 감사에 의존하게 된다.
- **`jq` 를 강하게 권한다.** 없으면 `python3` → `awk` 순으로 폴백하고,
  전부 실패하면 가드는 통과시킨다(fail open). 다만 `install.sh` 의
  settings 병합은 `jq` 없이는 거부한다.
- **macOS bash 3.2 / BSD userland 기준으로 작성했다.** `dash` 로도 교차 검증한다.

---

## 저장소 구조

```
install.sh                 설치·제거·진단
assets/                    설치 도구 (대상에 설치되지 않음)
.claude/
  agents/                  에이전트 5종
  skills/                  스킬 5종 (+ references, scripts)
  hooks/                   훅 6종 + _lib.sh
  settings.json            훅 배선
  tdd-guard.json           템플릿 자체 설정 (enabled: false)
fixtures/sandbox/          E2E 픽스처 (Gradle, 단일 모듈)
tests/                     Layer 1·2·3·4
```
