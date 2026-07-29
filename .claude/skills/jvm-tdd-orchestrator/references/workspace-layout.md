# `_workspace/` 규약

## 왜 파일인가

에이전트 간 데이터 전달 수단은 넷이다:

| 방식 | 도구 | 적합 |
|---|---|---|
| 메시지 | `SendMessage` | 실시간 조율 (팀 모드) |
| 태스크 | `TaskCreate`/`TaskUpdate` | 진행 상황·의존성 (팀 모드) |
| **파일** | 합의된 경로 | 크고 구조화된 산출물, **감사 추적** |
| 반환값 | `Agent` 결과 | 메인이 결과만 수거 |

이 하네스는 **파일 기반**을 기본으로 쓴다. 이유는 감사 추적이다.
사이클이 끝난 뒤 "왜 이 슬라이스를 골랐지", "그때 어떤 RED가 이 구현을
정당화했지"를 되짚을 수 있어야 한다. 메시지는 세션과 함께 사라진다.

## 파일 이름

```
{phase}_{agent}_{artifact}.{ext}
```

| 파일 | 쓰는 주체 | 내용 |
|---|---|---|
| `00_input/` | 오케스트레이터 | 사용자 요청, 참고 자료 |
| `02_designer_contract.md` | `tdd-contract-designer` | 계약, RED 목록, 경계면 표 |
| `02_author_testability.md` | `tdd-test-author` | (폴백 모드에서만) 관찰 가능성 검토 |
| `02_inspector_existing_boundaries.md` | `tdd-boundary-inspector` | (폴백 모드에서만) 기존 경계면 |
| `03_test-author_red.md` | `tdd-test-author` | 증명된 RED 기록 |
| `04_implementer_green.md` | `tdd-implementer` | 초록 기록, 남긴 부채 |
| `05_refactorer_report.md` | `tdd-refactorer` | 적용한 리팩터링 동작 |
| `06_inspector_boundaries.md` | `tdd-boundary-inspector` | 경계면 검증 결과 |

숫자 접두는 페이즈 번호다. 정렬하면 사이클 순서가 된다.

여러 사이클을 도는 경우(계약에 RED 항목이 여러 개) `03`/`04` 는 덮어쓰지 말고
회차를 붙인다:

```
03_test-author_red_1.md
04_implementer_green_1.md
03_test-author_red_2.md
04_implementer_green_2.md
```

## 삭제하지 않는다

중간 산출물은 사이클이 끝나도 **보존한다.** 이게 감사 추적의 전부다.

새 실행을 시작할 때는 지우는 대신 **아카이브**한다:

```sh
mv _workspace _workspace_$(date -u +%Y%m%d_%H%M%S)
mkdir -p _workspace/00_input
printf '*\n' > _workspace/.gitignore
```

## git 에서 감추기

`_workspace/.gitignore` 에 `*` 한 줄을 넣는다. **디렉토리가 자기 자신을 무시**하므로
대상 프로젝트의 `.gitignore` 를 건드릴 필요가 없다.

```sh
printf '*\n' > _workspace/.gitignore
```

아카이브한 디렉토리에도 같은 파일이 딸려 가므로 별도 조치가 필요 없다.

`.tdd-state/` 도 같은 기법을 쓴다.

공유 저장소에서 팀 전체가 이 하네스를 쓴다면 프로젝트 `.gitignore` 에 넣는 편이
명시적이다:

```sh
./install.sh --gitignore
```

기본값은 off 다 — 설치가 남의 저장소 파일을 말없이 고치는 건 무례하다.

## 부분 재실행

사용자가 "RED만 다시" 또는 "경계면 검증만 재실행" 을 요청하면:

1. `_workspace/` 를 **아카이브하지 않는다**
2. 해당 에이전트만 재호출한다
3. 프롬프트에 **이전 산출물 경로를 포함**해 기존 결과를 읽고 반영하게 한다
4. 그 에이전트의 산출물만 덮어쓴다

```
Agent(subagent_type: "tdd-boundary-inspector", model: "opus", prompt: "
  이전 검증 결과가 _workspace/06_inspector_boundaries.md 에 있다.
  그것을 읽고, 그 후 변경된 부분을 반영해 다시 검증하라.
  같은 경로에 덮어쓴다.
")
```

새 실행(전체 재시작)과 부분 재실행을 구분하는 것이 Phase 0의 역할이다.

## 상태 머신과의 관계

`_workspace/` 와 `.tdd-state/` 는 **직교**한다.

| | `_workspace/` | `.tdd-state/` |
|---|---|---|
| 쓰는 주체 | 에이전트 | 훅 (Gradle 관찰 결과) |
| 내용 | 판단·설계·기록 | 사실 (무엇이 실행됐고 무엇이 실패했나) |
| 신뢰도 | 에이전트가 쓴 것이므로 틀릴 수 있다 | Gradle이 쓴 XML 기반 |
| 수명 | 영구 (아카이브) | 사이클 단위 |

산출물이 "통과했습니다"라고 적혀 있어도 상태가 `RED_VERIFIED` 면
**상태가 맞다.** 판단이 갈리면 언제나 `.tdd-state/` 를 믿는다.
