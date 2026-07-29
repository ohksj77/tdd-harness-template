---
name: jvm-tdd-orchestrator
description: "Java/Kotlin 백엔드 기능을 TDD(RED→GREEN→REFACTOR)로 구현하는 에이전트 팀 오케스트레이터. 기능 추가, API 엔드포인트 구현, 서비스/리포지토리 작성, 버그 수정(재현 테스트 우선), 리팩터링 요청 시 반드시 사용. Spring Boot·JUnit5·AssertJ·Mockito·Gradle 프로젝트에서 '테스트부터', 'TDD로', '구현해줘', '엔드포인트 만들어줘', '이 버그 고쳐줘', '이 기능 추가해줘' 같은 요청에 트리거. 후속 작업에도 반드시 사용: 다시 실행, 재실행, 업데이트, 수정, 보완, 이전 결과 기반으로, 결과 개선, RED만 다시, GREEN 단계만 다시, 리팩터링만 추가로, 경계면 검증만 재실행, TDD 사이클이 막혔을 때 복구, 가드가 편집을 막을 때."
---

# JVM TDD Orchestrator

Java/Kotlin 백엔드 기능 하나를 RED→GREEN→REFACTOR 사이클로 완주시킨다.
사이클 위반은 훅이 차단하고, 이 스킬은 **누가 언제 무엇을 하는지**를 정한다.

## 실행 모드: 하이브리드

| Phase | 모드 | 이유 |
|---|---|---|
| 0 컨텍스트 확인 | 오케스트레이터 직접 | 상태 조회만 |
| 1 준비 | 오케스트레이터 직접 | I/O 만 |
| 2 계약 설계 | **에이전트 팀 (3명)** | 슬라이스·시그니처 상충을 실시간 토론으로 해소 |
| 3 RED | 서브 에이전트 | 단일 작성자. 상태 머신이 순서를 강제 |
| 4 GREEN | 서브 에이전트 | 순차 의존. 워크트리 단일 작성자 |
| 5 REFACTOR | 서브 에이전트 | 그린 바 유지가 유일한 계약. 협의 불필요 |
| 6 경계면 QA | 서브 에이전트 | 독립 객관 검증 |
| 7 결함 해소 (조건부) | **에이전트 팀 (2명)** | 생성-검증 피드백 루프, **최대 2회** |

**3~5 구간에서는 절대 팀 모드를 쓰지 않는다.** 팀원은 같은 워크트리에서
`.tdd-state/` 와 Gradle 데몬을 공유하므로, 동시 작성자는 상태를 서로 밟는다.

모든 `Agent` / `TeamCreate` 호출에 `model: "opus"` 를 넘긴다.

## 에이전트 구성

| 팀원 | 에이전트 타입 | 담당 | 산출물 |
|---|---|---|---|
| `tdd-contract-designer` | `Plan` | 계약 설계 | `_workspace/02_designer_contract.md` |
| `tdd-test-author` | 커스텀 | RED 작성·증명 | `_workspace/03_test-author_red.md` |
| `tdd-implementer` | 커스텀 | 최소 구현 | `_workspace/04_implementer_green.md` |
| `tdd-refactorer` | 커스텀 | 그린 바 리팩터링 | `_workspace/05_refactorer_report.md` |
| `tdd-boundary-inspector` | `general-purpose` | 경계면 검증 | `_workspace/06_inspector_boundaries.md` |

---

## 워크플로우

### Phase 0: 컨텍스트 확인

먼저 세 가지를 확인한다. 건너뛰면 중단된 사이클 위에 새 사이클을 얹게 된다.

1. **산출물 상태** — `_workspace/` 존재 여부로 실행 모드를 정한다
   - 미존재 → **초기 실행**. Phase 1로
   - 존재 + 부분 수정 요청 → **부분 재실행**. 해당 에이전트만 재호출하고,
     이전 산출물 경로를 프롬프트에 포함해 기존 결과를 읽고 반영하게 한다
   - 존재 + 새 입력 → **새 실행**. `_workspace/` 를
     `_workspace_{YYYYMMDD_HHMMSS}/` 로 옮긴 뒤 재생성

2. **TDD 상태** — `./.claude/hooks/tdd-state.sh status`

   | 상태 | 판단 |
   |---|---|
   | `IDLE` | 깨끗하다. 정상 진행 |
   | `RED_PENDING` | 이전 세션이 테스트를 쓰고 실행하지 않았다. 먼저 실행해 분류한다 |
   | `RED_VERIFIED` | 미완결 사이클이 있다. **Phase 4부터 이어받는다** |
   | `GREEN_VERIFIED` | 직전 사이클이 끝났다. 새 사이클 시작 가능 |
   | `REFACTOR` | 리팩터링 창이 열려 있다. `./gradlew test` 로 닫고 시작한다 |

   > 이 확인은 형식이 아니다. 훅이 서브에이전트 내부까지 발화하지 않는 환경일
   > 수 있으므로, 오케스트레이터가 **페이즈 경계마다 직접 상태를 읽어** 이중으로
   > 보증한다. Phase 3·4·5 시작 전과 종료 후에 각각 확인한다.

3. **팀 모드 가용성** — `printenv CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`
   - `1` 이면 Phase 2·7을 팀으로
   - 비어 있거나 `TeamCreate` 가 실패하면 → 서브 에이전트 폴백
     ([references/team-mode-fallback.md](references/team-mode-fallback.md))
   - **강등은 사용자에게 알린다.** 조용히 품질을 낮추지 않는다

### Phase 1: 준비

1. 요청을 분석한다 — 새 기능 / 버그 수정 / 순수 리팩터링 중 무엇인가
   - **순수 리팩터링 요청**이면 Phase 2~4를 건너뛰고 Phase 5로 간다
   - **버그 수정**이면 계약의 첫 항목이 반드시 재현 테스트다
2. `_workspace/` 를 만들고 `.gitignore` 에 `*` 한 줄을 넣는다 (자기 자신을 무시)
3. 입력 자료를 `_workspace/00_input/` 에 저장한다
4. 대상 모듈과 테스트 명령을 확정한다 (`./gradlew :module:test --tests '...'`)

### Phase 2: 계약 설계 — 에이전트 팀 (3명)

```
TeamCreate(
  team_name: "jvm-tdd-design",
  members: [
    { name: "designer",  agent_type: "tdd-contract-designer",  model: "opus",
      prompt: "_workspace/00_input/ 을 읽고 계약을 설계하라. 산출물: _workspace/02_designer_contract.md" },
    { name: "author",    agent_type: "tdd-test-author",        model: "opus",
      prompt: "계약이 테스트에서 관찰 가능한지 검토하고 즉시 피드백하라. 이 단계에서는 파일을 쓰지 않는다." },
    { name: "inspector", agent_type: "tdd-boundary-inspector", model: "opus",
      prompt: "계약이 기존 코드의 경계면과 충돌하는지 검토하고 즉시 피드백하라." }
  ]
)
```

작업 등록은 `TaskCreate` 로 하되, 팀원당 3~5개를 넘기지 않는다.

**완료 조건:** `_workspace/02_designer_contract.md` 에 실패 순서(RED 목록)와
경계면 계약 표가 채워졌고, 상충이 남았다면 「미해결 질문」에 병기되어 있을 것.

끝나면 `TeamDelete` 로 팀을 정리한다 — 서브 에이전트 구간으로 넘어가기 전에 필수다.

### Phase 3: RED — 서브 에이전트

계약의 **다음 한 항목**만 처리한다.

```
Agent(subagent_type: "tdd-test-author", model: "opus", prompt: "
  _workspace/02_designer_contract.md 의 RED 목록에서 아직 처리하지 않은 첫 항목을
  실패하는 테스트로 옮겨라. src/test 만 편집한다.
  ./gradlew :{module}:test --tests '{filter}' 로 RED를 실제로 증명하고
  _workspace/03_test-author_red.md 에 기록하라.
")
```

**종료 후 확인:** `tdd-state.sh status` 가 `RED_VERIFIED` 여야 한다.
아니면 Phase 3을 반복하지 말고 원인을 분류한다 (아래 에러 핸들링).

### Phase 4: GREEN — 서브 에이전트

```
Agent(subagent_type: "tdd-implementer", model: "opus", prompt: "
  _workspace/03_test-author_red.md 의 실패만 해소하는 최소 구현을 작성하라.
  테스트를 고치지 않는다. 계약 밖으로 나가지 않는다.
  통과를 확인하고 _workspace/04_implementer_green.md 에 기록하라.
")
```

**종료 후 확인:** `GREEN_VERIFIED` 여야 한다.

이어서 **경계면 증분 검증**을 돌린다 (Phase 6을 여기서 짧게 한 번).
마지막에 몰아서 하면 어긋난 지점이 여러 겹 쌓여 원인 분리가 불가능하다.

**계약에 남은 RED 항목이 있으면 Phase 3으로 돌아간다.** 사이클 반복이 정상이다.

### Phase 5: REFACTOR — 서브 에이전트

부채가 없으면 건너뛴다. 리팩터링 자체가 목적인 요청이면 여기서 시작한다.

```
Agent(subagent_type: "tdd-refactorer", model: "opus", prompt: "
  ./.claude/hooks/tdd-state.sh enter-refactor 로 창을 열고,
  _workspace/04_implementer_green.md 의 부채를 한 동작씩 처리하라.
  매 동작 후 테스트를 실행하고, 빨개지면 즉시 되돌려라.
  _workspace/05_refactorer_report.md 에 기록하고 초록으로 마감하라.
")
```

**종료 후 확인:** `GREEN_VERIFIED` 여야 한다. `REFACTOR` 로 남아 있으면
마감되지 않은 것이다.

### Phase 6: 경계면 QA — 서브 에이전트

```
Agent(subagent_type: "tdd-boundary-inspector", model: "opus", prompt: "
  이번 사이클의 변경분에 대해 경계면 계약을 검증하라.
  생산자와 소비자를 반드시 동시에 읽고 대조한다.
  _workspace/06_inspector_boundaries.md 에 파일:라인과 함께 기록하라.
")
```

### Phase 7: 결함 해소 — 에이전트 팀 (2명), 조건부

Phase 6에서 「불일치」가 나온 경우에만. `tdd-implementer` 와
`tdd-boundary-inspector` 로 생성-검증 루프를 돈다.

**최대 2회.** 2회 안에 해소되지 않으면 남은 항목을 사용자에게 올린다.
무한 루프는 이 패턴의 최악 실패 모드이며, 상한은 협상 대상이 아니다.

### Phase 8: 마감

1. `TeamDelete` (팀이 살아 있으면)
2. `./gradlew :{module}:test` 로 전체 초록 확인
3. `_workspace/` 는 **보존한다** — 사후 검증·감사 추적용
4. 사용자에게 보고: 처리한 RED 항목, 남은 계약 항목, 미해소 경계면 이슈,
   실행 모드(팀/폴백), 사용된 가드 우회

---

## 데이터 흐름

```
사용자 요청
    │
    ▼
_workspace/00_input/
    │
    ▼  Phase 2 (팀)
_workspace/02_designer_contract.md ──────────────┐
    │                                            │
    ▼  Phase 3 (서브)                            │
_workspace/03_test-author_red.md                 │ 계약은 모든
    │        └─ 상태: RED_VERIFIED               │ 하위 단계가
    ▼  Phase 4 (서브)                            │ 읽는다
_workspace/04_implementer_green.md               │
    │        └─ 상태: GREEN_VERIFIED             │
    ├──────────────► (RED 항목 남음) ─► Phase 3  │
    ▼  Phase 5 (서브)                            │
_workspace/05_refactorer_report.md               │
    │                                            │
    ▼  Phase 6 (서브)                            │
_workspace/06_inspector_boundaries.md ◄──────────┘
    │
    ├── 불일치 있음 ─► Phase 7 (팀, 최대 2회) ─┐
    │                                          │
    ▼◄─────────────────────────────────────────┘
Phase 8 마감 보고
```

상태 머신(`.tdd-state/`)은 이 흐름과 **직교**한다. 산출물은 에이전트가 쓰고,
상태는 Gradle 실행 결과로만 바뀐다. 그래서 산출물이 거짓말을 해도 상태는 못 속인다.

---

## 에러 핸들링

| 상황 | 대응 |
|---|---|
| **가드가 편집을 차단** | 거부 메시지가 다음 명령을 지명한다. 그대로 따른다. 우회(`TDD_GUARD=off`, `BYPASS`)는 사용자가 명시적으로 요청할 때만 |
| `RED_PENDING` 에서 진행 불가 | 테스트를 실제로 실행한다. 컴파일 실패도 정당한 RED다 |
| `main-compile-broken` | RED가 아니다. 직전 편집을 되돌린다 |
| `infra-red` (의존성·Docker) | 환경 문제. 테스트를 고치지 않는다. 사용자에게 보고 |
| `no-fresh-results` (UP-TO-DATE) | `--rerun-tasks` 또는 `cleanTest` 로 재실행 |
| RED를 만들려는데 초록이 나옴 | 이미 구현된 항목이다. 계약의 다음 항목으로 |
| 구현이 계약을 벗어나야 함 | 멈추고 Phase 2로 되돌아가 계약을 고친다 |
| 리팩터링 중 테스트가 빨개짐 | 즉시 되돌린다. 디버깅하지 않는다 |
| `enter-refactor` 거부 | `./gradlew test` 로 초록을 재확인한 뒤 재시도 |
| 리팩터링 예산/기한 소진 | 단위가 크다는 신호. 초록으로 마감하고 쪼갠다 |
| **팀원 1명 실패** | 남은 팀원으로 진행하고, 빠진 관점을 산출물에 명시 |
| **팀원 과반 실패** | 사용자에게 알리고 진행 여부를 묻는다 |
| `TeamCreate` 실패 (플래그 없음) | 서브 에이전트 폴백. **강등을 알린다** |
| Phase 7이 2회를 넘김 | 중단. 남은 불일치를 사용자에게 올린다 |
| 팀원 간 판단 상충 | 양쪽을 출처와 함께 병기한다. 조용히 한쪽을 고르지 않는다 |
| Stop 훅이 종료를 차단 | 상태를 읽고 그 요구를 처리한다. 2회 차단 후에는 자동 허용된다 |

---

## 테스트 시나리오

### 정상 흐름

1. "주문 취소 API 만들어줘" → Phase 0: `_workspace/` 없음, 상태 `IDLE`, 팀 플래그 `1`
2. Phase 1: `_workspace/` 생성, 대상 모듈 `:order-api` 확정
3. Phase 2: 팀 3명 → 계약에 RED 4항목, 경계면 3건 확정
4. Phase 3: 첫 테스트 작성 → `compile-red` → `RED_VERIFIED`
5. Phase 4: 최소 구현 → `GREEN_VERIFIED` → 경계면 증분 검증 통과
6. Phase 3~4를 나머지 3항목 반복
7. Phase 5: 부채 2건 리팩터링, 매번 초록 유지
8. Phase 6: 경계면 검증 — 불일치 0건
9. Phase 8: 전체 초록 확인 후 보고

### 에러 흐름 A — 초록 상태에서 프로덕션을 고치려 함

1. Phase 4 종료, 상태 `GREEN_VERIFIED`
2. 다음 요구를 구현하려고 `src/main` 편집 시도 → **가드가 exit 2로 차단**
3. 거부 메시지: "새 실패 테스트를 쓰거나 enter-refactor 를 실행하라"
4. 오케스트레이터가 판단:
   - 새 동작이면 → Phase 3으로 (테스트 먼저)
   - 동작 불변 개선이면 → Phase 5로 (`enter-refactor`)
5. 어느 쪽이든 사이클이 복구된다. **재시도로 뚫으려 하지 않는다**

### 에러 흐름 B — 팀 모드를 쓸 수 없음

1. Phase 0에서 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` 가 비어 있음
2. Phase 2를 서브 에이전트 3개 병렬로 폴백
   (`run_in_background: true`, 각자 `_workspace/02_*_{역할}.md` 에 기록)
3. 오케스트레이터가 **상충 지점 표**를 직접 작성해 조정한다 —
   실시간 토론이 없었으므로 이 조정이 팀 모드의 대체물이다
4. 사용자에게 강등 사실과 조정 내역을 보고한다

### 에러 흐름 C — 중단된 사이클 이어받기

1. 새 세션 시작, Phase 0에서 상태 `RED_VERIFIED` 발견
2. `_workspace/03_test-author_red.md` 를 읽어 무엇이 실패 중인지 파악
3. Phase 2·3을 건너뛰고 **Phase 4부터** 이어받는다
4. 새 계약을 만들지 않는다 — 기존 계약을 계속 쓴다

---

## 더 읽기

- 상태 머신과 가드 메시지 해석: [references/tdd-state-machine.md](references/tdd-state-machine.md)
- 팀 모드 폴백 절차: [references/team-mode-fallback.md](references/team-mode-fallback.md)
- `_workspace/` 규약: [references/workspace-layout.md](references/workspace-layout.md)
