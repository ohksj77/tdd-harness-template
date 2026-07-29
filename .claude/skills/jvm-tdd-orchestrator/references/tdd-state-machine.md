# TDD 상태 머신과 가드 메시지 해석

## 목차

1. [상태와 전이](#상태와-전이)
2. [무엇이 상태를 바꾸는가](#무엇이-상태를-바꾸는가)
3. [가드가 지키는 범위](#가드가-지키는-범위)
4. [거부 메시지별 대응](#거부-메시지별-대응)
5. [탈출구](#탈출구)
6. [CLI 레퍼런스](#cli-레퍼런스)
7. [설정](#설정)

---

## 상태와 전이

| 상태 | `src/main/{java,kotlin}` 편집 | 뜻 |
|---|---|---|
| `IDLE` | 차단 | 진행 중인 사이클 없음 |
| `RED_PENDING` | 차단 | 테스트가 수정됐지만 실행되지 않음 |
| `RED_VERIFIED` | **허용** | 실패가 실제로 증명됨 |
| `GREEN_VERIFIED` | 차단 | 바가 초록. 다음 동작은 새 테스트부터 |
| `REFACTOR` | **허용** (예산·기한 내) | 동작 불변을 선언한 창 |

```
IDLE ──src/test 편집──► RED_PENDING ──gradle: red──► RED_VERIFIED
                             │                            │
                             └──gradle: green───► GREEN_VERIFIED ◄──┐
                                                        │            │
                                         enter-refactor │       gradle: green
                                                        ▼       / 예산 소진
                                                    REFACTOR ────────┘
                                                        │
                                              gradle: red ──► RED_VERIFIED
                                              (리팩터링이 깨뜨림 → 즉시 되돌려라)
```

### `enter-refactor` 신선도 규칙

세 조건을 **모두** 만족해야 창이 열린다:

1. 상태가 `GREEN_VERIFIED`
2. 마지막 초록 이후 `src/main` 편집이 0회
3. 마지막 초록이 15분 이내

"테스트 돌려놓고 딴짓하다 와서 리팩터 권한을 주장하는" 경로를 막는다.
전부 `./gradlew test` 한 번으로 해결된다.

---

## 무엇이 상태를 바꾸는가

**Gradle이 쓴 파일만이 상태를 바꾼다.** 에이전트의 선언은 아무 효력이 없다.

| 사건 | 훅 | 결과 |
|---|---|---|
| `src/test/**` 편집 | `tdd-mark-edit.sh` | `IDLE`/`GREEN` → `RED_PENDING` |
| `gradle` 실행 후 실패 XML | `tdd-record-run.sh` | → `RED_VERIFIED` (assertion) |
| `gradle` 실행 후 테스트 컴파일 실패 | `tdd-record-run.sh` | → `RED_VERIFIED` (compile) |
| `gradle` 실행 후 전부 통과 | `tdd-record-run.sh` | → `GREEN_VERIFIED` |
| `enter-refactor` | `tdd-state.sh` | `GREEN_VERIFIED` → `REFACTOR` |
| `src/main/**` 편집 | `tdd-mark-edit.sh` | 카운터 증가 (상태는 유지) |

`TEST-*.xml` 은 **mtime 게이트**를 통과해야 인정된다. 오래된 초록을 재생해
통과한 척할 수 없다.

전이 이력은 전부 `.tdd-state/events.log` 에 남는다:

```sh
./.claude/hooks/tdd-state.sh events 30
```

---

## 가드가 지키는 범위

**딱 두 곳만 지킨다:**

```
*/src/main/java/**.java
*/src/main/kotlin/**.kt
```

나머지는 상태를 보기도 전에 통과한다:

| 항상 허용 | 이유 |
|---|---|
| `src/test/**` | 테스트 작성은 언제나 옳다 |
| `build.gradle(.kts)`, `settings.gradle`, `gradle.properties`, `libs.versions.toml` | 빌드 설정은 TDD 사이클의 대상이 아니다 |
| `src/main/resources/**` (yml, SQL, properties) | 설정·마이그레이션 |
| `.claude/**`, `_workspace/**` | 하네스 자신 |
| `*.md`, `Dockerfile`, `.github/**` | 문서·인프라 |

이게 오탐 대책의 1순위다. "설정 파일 예외"를 예외 목록으로 관리하면 목록이
영원히 자라지만, **스코프**로 처리하면 오탐의 대부분이 구조적으로 사라진다.

기본 `allowPatterns` 로 추가 면제되는 것:
`**/*Application.java`, `**/*Application.kt`, `**/generated/**`,
`**/build/generated/**`, `**/package-info.java`

---

## 거부 메시지별 대응

### "진행 중인 TDD 사이클이 없습니다 (상태: IDLE)"

`src/test` 에 실패하는 테스트를 먼저 쓴다.

신규 모듈 뼈대처럼 테스트가 선행할 수 없는 경우에만:

```sh
./.claude/hooks/tdd-state.sh grant-scaffold \
  --glob '*/payment/src/main/*' --reason '신규 모듈 부트스트랩' --ttl 20m
```

시간 제한이고, 동시에 하나만 유효하며, 감사 로그에 남는다.

### "테스트를 수정했지만 아직 실행하지 않았습니다"

```sh
./gradlew :core:test --tests '*YourTest'
```

컴파일 실패가 나도 괜찮다 — 그것도 정당한 RED다.

### "바가 초록입니다"

둘 중 하나를 고른다:

- 새 동작을 추가하는 중 → 실패하는 테스트를 먼저 쓴다
- 동작을 바꾸지 않는 개선 → `./.claude/hooks/tdd-state.sh enter-refactor`

**어느 쪽인지 모르겠다면 새 테스트 쪽이다.**

### "리팩터링 시간 창이 만료되었습니다" / "편집 예산을 소진했습니다"

```sh
./gradlew test    # 초록이면 예산이 초기화된다
```

반복해서 부딪힌다면 리팩터링 단위가 너무 크다는 신호다. 쪼개라.

### "⚠ ...은(는) 현재 실패 테스트와 직접 연결되지 않습니다" (경고, 차단 아님)

기본 `scopeMode: "warn"` 에서는 통과시키고 경고만 낸다.
`OrderServiceTest` 가 다른 패키지의 새 `Money` 타입을 요구하는 것은 정상적인
설계이고, 이걸 하드 차단하는 가드는 하루 만에 꺼진다.

경고가 자주 뜨면 사이클을 좁힐 여지가 있다는 뜻이지 잘못했다는 뜻은 아니다.

`scopeMode: "strict"` 로 올리면 차단이 된다.

### Stop 훅: "RED 상태로 끝낼 수 없습니다"

구현으로 초록을 만들거나, 이번 사이클을 포기한다면 테스트를 되돌린다.

```sh
./.claude/hooks/tdd-state.sh reset
```

세션당 **2회까지만** 차단하고 그 다음부터는 강제로 통과시킨다.
무한 루프는 훅 게이트의 최악 실패 모드다.

---

## 탈출구

전부 `.tdd-state/events.log` 에 기록되고, Stop 훅이 누적 횟수를 보고한다.
탈출구가 비밀이 되지 않게 하려는 설계다.

| 방법 | 범위 | 쓸 때 |
|---|---|---|
| `TDD_GUARD=off` (환경변수) | 한 명령 | 긴급 |
| `.tdd-state/BYPASS` 파일 | 파일을 지울 때까지 | 대규모 마이그레이션 |
| `grant-scaffold` | 글롭 + 시간 제한 | 신규 모듈 뼈대 |
| `tdd-guard.json` 의 `"enabled": false` | 프로젝트 전체 | 하네스를 끌 때 |

```sh
./.claude/hooks/tdd-state.sh bypass on
# ... 작업 ...
./.claude/hooks/tdd-state.sh bypass off
```

같은 유형의 우회가 반복된다면 가드 설정이 아니라 **하네스 구성을 손봐야 한다는
신호**다 (Harness Phase 7 진화 트리거).

---

## CLI 레퍼런스

```sh
./.claude/hooks/tdd-state.sh status            # 현재 상태와 근거
./.claude/hooks/tdd-state.sh explain           # 상태 머신 전체 설명
./.claude/hooks/tdd-state.sh enter-refactor    # 리팩터링 창 열기
./.claude/hooks/tdd-state.sh grant-scaffold --glob '<G>' --reason '<R>' --ttl 20m
./.claude/hooks/tdd-state.sh bypass on|off
./.claude/hooks/tdd-state.sh reset             # IDLE 로 초기화
./.claude/hooks/tdd-state.sh events 30         # 최근 감사 로그
```

환경변수:

| 변수 | 효과 |
|---|---|
| `TDD_GUARD=off` | 그 호출에 한해 가드 통과 |
| `TDD_REFACTOR_TTL=3600` | 리팩터링 창 길이 (초, 기본 1800) |
| `TDD_JSON_TIER=jq\|python3\|awk` | JSON 파서 강제 (디버깅용) |

---

## 설정

`.claude/tdd-guard.json`:

```json
{
  "enabled": true,
  "scopeMode": "warn",
  "postEditNormalize": true,
  "formatOnStop": true,
  "allowPatterns": ["**/*Application.java", "**/generated/**"]
}
```

| 키 | 값 | 기본 | 뜻 |
|---|---|---|---|
| `enabled` | bool | `true` | 가드 전체 on/off |
| `scopeMode` | `warn` \| `strict` \| `off` | `warn` | 파일 스코프 불일치 처리 |
| `postEditNormalize` | bool | `true` | 편집 후 후행 공백 정리 |
| `formatOnStop` | bool | `true` | Stop 시 `spotlessApply`/`ktlintFormat` 일괄 실행 |
| `allowPatterns` | string[] | 위 참조 | 가드 면제 글롭 |

`postEditNormalize` 를 껐을 때가 나은 경우: 편집 후 파일이 바뀌면 Claude의
파일 스냅샷과 어긋나 다음 `Edit` 이 문자열 불일치로 실패할 수 있다.
그런 증상이 보이면 `false` 로 두라.
