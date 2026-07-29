---
name: gradle-test-execution
description: "Gradle 테스트를 좁게 실행하고 실패를 정확히 분류하는 방법. ./gradlew test 실행, --tests 필터, 멀티모듈 :module:test, 실패 원인 판별(컴파일 실패 vs 어서션 실패 vs 환경 문제), UP-TO-DATE 로 결과가 안 나올 때, 테스트 결과 XML 읽기, 느린 테스트 진단에 사용. TDD 상태 머신이 이 분류를 근거로 전이하므로 RED/GREEN 판정이 필요할 때 반드시 참조. 재실행, 다시 돌려줘, 왜 안 도냐, 테스트가 왜 실패하냐 같은 후속 요청에도 사용."
---

# Gradle 테스트 실행과 실패 분류

TDD 사이클의 속도는 테스트 실행 시간이 결정하고, TDD 사이클의 정확성은
**실패를 올바로 분류하는 능력**이 결정한다. "빨갛다"는 신호가 아니다.
왜 빨간지가 신호다.

## 1. 좁게 실행하라

```sh
./gradlew :core:test --tests '*UserServiceTest'                   # 클래스 하나
./gradlew :core:test --tests '*UserServiceTest.rejectsUnknownId'  # 메서드 하나
./gradlew :core:test --tests 'com.acme.user.*'                    # 패키지
```

전체 스위트(`./gradlew test`)는 사이클 끝에서 한 번이면 족하다.
루프 안에서 30초를 기다리기 시작하면 사람이든 에이전트든 테스트를 건너뛰게 된다.

멀티모듈에서는 **모듈을 반드시 지정**한다. `./gradlew test` 는 모든 모듈을 돈다.

```sh
./gradlew :order-api:test --tests '*OrderControllerTest'
```

번들 스크립트를 쓰면 아래 항목이 자동으로 붙는다 (`--console=plain`, 로그 tee,
결과 요약):

```sh
./.claude/skills/gradle-test-execution/scripts/run-tests.sh :core '*UserServiceTest'
./.claude/skills/gradle-test-execution/scripts/summarize-results.sh
```

## 2. 실패 분류표 — TDD 상태 머신이 쓰는 바로 그 기준

| 분류 | 신호 | TDD 의미 | 다음 행동 |
|---|---|---|---|
| `compile-red` | `compileTestJava\|compileTestKotlin FAILED` + `cannot find symbol` / `Unresolved reference` / `package ... does not exist` | **정당한 RED.** 컴파일러가 첫 어서션이다 | 구현으로 넘어간다 |
| `assertion-red` | `TEST-*.xml` 의 `failures` 또는 `errors` > 0 | **정당한 RED** | 구현으로 넘어간다 |
| `main-compile-broken` | `compileJava\|compileKotlin FAILED` (메인 소스셋) | **RED 아님.** 프로덕션이 깨졌다 | 직전 변경을 되돌린다 |
| `infra-red` | `Could not resolve`, `Connection refused`, Docker/Testcontainers 오류 | **RED 아님.** 환경 문제 | 환경을 고친다. 테스트를 건드리지 않는다 |
| `no-fresh-results` | 태스크 `UP-TO-DATE`, 새 XML 없음 | 아무 일도 일어나지 않았다 | `--rerun-tasks` 또는 `cleanTest` |

상세한 판별 규칙과 실제 로그 예시: [references/failure-taxonomy.md](references/failure-taxonomy.md)

### 왜 컴파일 실패가 정당한 RED 인가

JVM에서 새 동작을 요구하는 첫 테스트는 대부분 **아직 없는 타입을 참조**한다.

```java
// UserService 가 아직 존재하지 않는다
var service = new UserService(repository);
```

이때 Gradle은 테스트를 **실행조차 하지 못하므로 `TEST-*.xml` 을 쓰지 않는다.**
XML만 보는 도구는 여기서 "RED가 아니다"라고 판정하고, 그러면 첫 사이클에서
영원히 진행할 수 없다.

컴파일러는 이 순간 어서션 역할을 하고 있다. `cannot find symbol: class UserService`
는 "UserService 가 있어야 한다"는 실패한 명세다. 이건 정당한 RED다.

**따라서 클래스가 없다는 이유로 급히 빈 클래스를 만들지 마라.** 그건 테스트가
요구하지 않은 프로덕션 편집이고, RED를 지워 버리는 행위다.

## 3. UP-TO-DATE 함정

Gradle의 `test` 태스크는 입력이 바뀌지 않으면 건너뛴다. 그러면 새 XML이 없고,
상태 머신은 "아무 일도 없었다"고 판단한다 — **의도된 동작이다.** 오래된 초록을
재생해서 통과한 척하는 것보다 낫다.

```sh
./gradlew :core:test --tests '*UserServiceTest' --rerun-tasks   # 강제 재실행
./gradlew :core:cleanTest :core:test --tests '*UserServiceTest' # 결과까지 삭제
```

주의: 직전 실행이 **실패**했다면 태스크는 UP-TO-DATE가 되지 않는다.
실패한 테스트를 남겨 둔 채로는 UP-TO-DATE를 볼 수 없다.

## 4. 출력을 읽을 수 있게 유지하라

```sh
./gradlew :core:test --tests '*Xxx' --console=plain
```

`--console=rich`(기본)는 ANSI 커서 제어로 진행 표시를 덮어써서, 로그를 캡처하면
컴파일 오류 줄이 통째로 사라질 수 있다. 실패 분류가 로그에 의존하므로
**`--console=plain` 을 항상 붙인다.** 번들 `run-tests.sh` 가 이걸 강제한다.

구성 캐시(`org.gradle.configuration-cache=true`)도 태스크 출력을 억제할 수 있다.
분류가 이상하면 `--no-configuration-cache` 로 한 번 확인한다.

## 5. 결과 XML 직접 읽기

```
{module}/build/test-results/test/TEST-{FQCN}.xml
```

한 줄짜리 `<testsuite ...>` 속성에 `tests` / `failures` / `errors` / `skipped` 가 있다.
XML 파서 없이 grep 으로 읽을 수 있게 설계된 포맷이다.

```sh
grep -h '<testsuite ' */build/test-results/test/TEST-*.xml
```

`<failure>` / `<error>` 본문의 스택트레이스는 **실제 협력자 타입을 지명**하므로
"이 실패가 어떤 프로덕션 파일을 요구하는가"를 판단하는 가장 강한 근거다.

HTML 리포트: `{module}/build/reports/tests/test/index.html`

## 6. 느릴 때

| 증상 | 원인 | 조치 |
|---|---|---|
| 첫 실행만 느림 | 의존성 다운로드 | 정상 |
| 매번 5초+ 시작 | 데몬 미사용 | `--no-daemon` 을 빼라 (CI 말고는 데몬을 켠다) |
| 테스트당 수 초 | Spring 컨텍스트 재생성 | `@MockBean` 남용 확인 → `spring-test-slice-selection` |
| 전체가 느림 | 필터 없이 전체 실행 | `--tests` 로 좁혀라 |

멀티모듈 구성, 커스텀 소스셋(`integrationTest`), 병렬 실행:
[references/multi-module.md](references/multi-module.md)

## 7. TDD 상태 머신과의 관계

훅이 자동으로 관찰하므로 별도 보고가 필요 없다. 다만 상태가 예상과 다르면:

```sh
./.claude/hooks/tdd-state.sh status    # 현재 상태와 근거
./.claude/hooks/tdd-state.sh explain   # 상태 머신 전체와 막혔을 때 할 일
./.claude/hooks/tdd-state.sh events 20 # 최근 전이 감사 로그
```

상태는 **Gradle이 쓴 파일**로만 바뀐다. 에이전트가 "통과했습니다"라고 선언해서
바뀌지 않는다. 그래서 실행을 건너뛸 수 없다.
