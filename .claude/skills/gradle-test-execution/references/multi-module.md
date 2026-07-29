# 멀티모듈과 실행 함정

## 모듈을 반드시 지정하라

```sh
./gradlew test                              # 모든 모듈 — 사이클 안에서 쓰면 안 된다
./gradlew :order-api:test                   # 모듈 하나
./gradlew :order-api:test --tests '*OrderControllerTest'
```

모듈 경로는 `settings.gradle.kts` 의 `include(...)` 와 같다.
중첩 모듈은 `:services:order-api:test` 처럼 콜론으로 잇는다.

모듈 이름이 기억나지 않으면:

```sh
./gradlew projects
```

## `--tests` 패턴

| 패턴 | 매칭 |
|---|---|
| `'*UserServiceTest'` | 아무 패키지의 `UserServiceTest` |
| `'com.acme.user.UserServiceTest'` | FQCN 정확히 |
| `'*UserServiceTest.rejectsUnknownId'` | 메서드 하나 |
| `'com.acme.user.*'` | 패키지 전체 |
| `'*Order*'` | 이름에 Order 가 들어가는 전부 |

**따옴표를 반드시 쓴다.** 셸이 `*` 를 파일명으로 확장해 버리면 조용히 엉뚱한
필터가 들어간다.

여러 필터를 주면 OR 로 합쳐진다:

```sh
./gradlew :core:test --tests '*UserServiceTest' --tests '*OrderServiceTest'
```

패턴이 아무것도 매칭하지 않으면 Gradle이 실패한다 (`No tests found for given includes`).
이건 `infra-red` 도 RED도 아니고, 필터가 틀린 것이다.

## 커스텀 소스셋

`integrationTest`, `e2eTest` 같은 소스셋은 별도 태스크를 가진다:

```sh
./gradlew :order-api:integrationTest --tests '*OrderFlowIT'
```

결과 XML 경로도 소스셋별로 갈린다:

```
{module}/build/test-results/{taskName}/TEST-*.xml
```

상태 머신은 `build/test-results/` 아래를 전부 스캔하므로 커스텀 소스셋도
자동으로 인식한다. 다만 통합 테스트는 느리므로 **TDD 루프 안에서는 쓰지 마라.**
사이클은 단위 테스트로 돌리고, 통합 테스트는 사이클 마감에 한 번 돌린다.

## 의존 모듈이 함께 빌드된다

`:order-api` 가 `:core` 에 의존하면 `:order-api:test` 는 `:core:compileJava` 를
먼저 돌린다. 따라서 `:core` 의 프로덕션 코드가 깨져 있으면
`:order-api:test` 도 `main-compile-broken` 으로 실패한다.

실패한 모듈 이름을 로그에서 확인하라 — 내가 건드린 모듈이 아닐 수 있다.

```
> Task :core:compileJava FAILED     ← 여기가 원인
```

## 구성 캐시와 데몬

| 설정 | TDD 루프에서 |
|---|---|
| `org.gradle.daemon=true` (기본) | **켜라.** 끄면 실행마다 JVM 기동 5초+ |
| `org.gradle.caching=true` | 켜도 된다. 단 분류가 이상하면 의심하라 |
| `org.gradle.configuration-cache=true` | 태스크 출력을 억제해 compile-red 판별을 방해할 수 있다. 이상하면 `--no-configuration-cache` 로 확인 |
| `org.gradle.parallel=true` | 멀티모듈에서 유용. 단 로그가 섞여 읽기 어려워진다 |

`--no-daemon` 은 CI에서만 쓴다. 로컬 TDD 루프에서 쓰면 사이클이 감당 못 하게 느려진다.

## UP-TO-DATE 를 뚫는 법

```sh
./gradlew :core:test --tests '*Xxx' --rerun-tasks   # 이 태스크만 강제 재실행
./gradlew :core:cleanTest :core:test --tests '*Xxx' # 이전 결과 XML 도 삭제
./gradlew :core:test --rerun                        # Gradle 8+ 개별 태스크 재실행
```

`clean` 전체는 쓰지 마라 — 모든 모듈을 다시 컴파일하느라 사이클이 죽는다.

## 결과 XML 위치 정리

```
{module}/build/test-results/test/TEST-{FQCN}.xml     기본 test 태스크
{module}/build/test-results/{task}/TEST-{FQCN}.xml   커스텀 소스셋
{module}/build/reports/tests/test/index.html          사람이 읽는 HTML
```

여러 모듈을 한 번에 훑기:

```sh
grep -h '<testsuite ' */build/test-results/*/TEST-*.xml
find . -name 'TEST-*.xml' -path '*/build/test-results/*' -newermt '-5 minutes'
```

## 테스트가 느릴 때 원인 찾기

```sh
./gradlew :core:test --profile        # build/reports/profile/ 에 리포트
./gradlew :core:test --scan           # Develocity (동의 필요)
```

가장 흔한 원인은 Spring 컨텍스트 재생성이다. `@MockBean` 이 컨텍스트 캐시 키를
바꿔서 테스트 클래스마다 컨텍스트가 새로 뜬다. 진단과 대책은
`spring-test-slice-selection` 스킬의 `references/slice-catalog.md` 를 보라.
