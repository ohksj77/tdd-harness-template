# 팀 모드 폴백

## 무엇이 플래그에 걸려 있는가

`TeamCreate`, `SendMessage`, `TaskCreate` 는 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
을 요구한다. `Agent` 도구는 정식 기능이라 플래그와 무관하다.

플래그가 없으면 팀 기반 페이즈는 **조용히 단일 에이전트로 퇴화**한다.
이 하네스는 조용한 퇴화를 허용하지 않는다 — 탐지하고, 폴백하고, 알린다.

## 탐지

Phase 0 에서:

```sh
printenv CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
```

`1` 이 아니면 폴백 모드. 값이 `1` 이어도 `TeamCreate` 가 실패하면 **같은 신호로
취급**한다 — 환경변수가 켜져 있다고 기능이 있다는 보장은 아니다.

켜는 법 (사용자에게 안내):

```sh
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

## 영향받는 페이즈

| Phase | 팀 모드 | 폴백 |
|---|---|---|
| 2 계약 설계 | 3명 실시간 토론 | 병렬 서브 3개 + 오케스트레이터 조정 |
| 7 결함 해소 | 2명 생성-검증 루프 | 순차 서브 왕복 (상한 동일) |
| 3·4·5·6 | 원래 서브 | 영향 없음 |

RED→GREEN→REFACTOR 는 원래 서브 에이전트 구간이므로 **핵심 사이클은
플래그 없이도 완전히 동작한다.** 잃는 것은 설계 단계의 실시간 조율뿐이다.

## Phase 2 폴백 절차

### 1. 병렬 서브 에이전트 3개

단일 메시지에서 세 개를 동시에 호출한다:

```
Agent(subagent_type: "tdd-contract-designer", model: "opus", run_in_background: true,
      prompt: "... 산출물: _workspace/02_designer_contract.md")

Agent(subagent_type: "tdd-test-author", model: "opus", run_in_background: true,
      prompt: "계약 초안 없이, 이 요구사항을 테스트로 옮길 때 관찰 가능해야 하는
               시그니처와 슬라이스를 제시하라. 파일을 편집하지 마라.
               산출물: _workspace/02_author_testability.md")

Agent(subagent_type: "tdd-boundary-inspector", model: "opus", run_in_background: true,
      prompt: "이 요구사항이 닿는 기존 경계면을 조사하고 기존 계약을 문서화하라.
               산출물: _workspace/02_inspector_existing_boundaries.md")
```

세 에이전트는 서로를 보지 못한다. 그래서 조정이 필요하다.

### 2. 상충 지점 표 — 조정이 팀 모드의 대체물이다

세 산출물을 읽고 **오케스트레이터가 직접** 표를 만든다:

```markdown
## 상충 지점 (팀 모드 폴백 — 오케스트레이터 조정)

| # | 쟁점 | designer | author | inspector | 채택 | 근거 |
|---|------|----------|--------|-----------|------|------|
| 1 | 반환 타입 | `OrderResponse` | `Optional<OrderResponse>` | 기존 컨트롤러는 404 반환 | 예외 + @ControllerAdvice | 기존 계약 우선 |
| 2 | 슬라이스 | `@SpringBootTest` | `@WebMvcTest` | - | `@WebMvcTest` | 더 좁은 쪽 |
| 3 | 필드명 | `total` | - | 기존 DTO 는 `totalAmount` | `totalAmount` | 기존 계약 우선 |
```

조정 원칙:

1. **기존 계약이 이긴다.** 이미 배포된 API 모양은 설계 선호보다 강하다
2. **더 좁은 슬라이스가 이긴다**
3. **테스트에서 관찰 가능한 쪽이 이긴다**
4. 위 셋으로 안 풀리면 **양쪽을 병기하고 사용자에게 올린다** —
   조용히 한쪽을 고르면 나중에 아무도 근거를 찾을 수 없다

이 표를 `_workspace/02_designer_contract.md` 의 「미해결 질문」 앞에 붙인다.

### 3. 강등 보고

마감 보고에 반드시 포함한다:

```
실행 모드: 하이브리드 (Phase 2 폴백 — 에이전트 팀 사용 불가)
  · CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS 미설정
  · Phase 2를 병렬 서브 에이전트 3개로 대체하고 상충 3건을 오케스트레이터가 조정
  · 조정 내역: _workspace/02_designer_contract.md 의 「상충 지점」 표
```

**품질 저하를 숨기지 않는다.** 사용자가 이 사실을 알아야 조정 결과를 검토할지
판단할 수 있다.

## Phase 7 폴백 절차

생성-검증 루프를 순차로 돌린다.

```
반복 (최대 2회):
  Agent(tdd-implementer)          # 지적사항 수정
  Agent(tdd-boundary-inspector)   # 재검증
  불일치 0건이면 종료
```

**상한은 팀 모드와 동일하게 2회다.** 폴백이라고 완화하지 않는다.

## 팀 모드 전환 규칙 (플래그가 있을 때)

| 전환 | 필요한 조치 |
|---|---|
| 팀 → 서브 | 먼저 `TeamDelete` |
| 서브 → 팀 | 파일 경로를 팀원 프롬프트에 전달 |
| 팀 → 팀 | 먼저 `TeamDelete`, 그 다음 `TeamCreate` |

한 세션에 활성 팀은 하나다. 팀원은 팀을 만들 수 없다 (중첩 불가).

**Phase 2가 끝나면 반드시 `TeamDelete` 한다.** Phase 3부터는 서브 구간이고,
살아 있는 팀원이 같은 워크트리에서 `.tdd-state/` 를 건드리면 상태가 꼬인다.

## 왜 3~5는 애초에 팀이 아닌가

플래그가 있어도 RED→GREEN→REFACTOR 는 서브 에이전트로 돈다:

1. **엄격한 순차 의존** — RED 없이 GREEN이 없다. 병렬성이 0이다
2. **단일 작성자** — 같은 워크트리에 동시 작성자가 있으면
   `.tdd-state/` 와 Gradle 데몬을 두고 경쟁한다
3. **협의할 것이 없다** — "이 실패를 통과시킨다"는 계약에 토론의 여지가 없다

팀 모드는 실시간 이견 조율이 값어치를 할 때만 쓴다. 그게 Phase 2와 7이다.
