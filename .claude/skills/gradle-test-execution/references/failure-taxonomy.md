# 실패 분류법 — 빨간 것과 RED 는 다르다

TDD 상태 머신은 이 분류를 근거로 전이한다. 잘못 분류하면 사이클이 잘못된 방향으로
간다. "테스트가 안 된다"는 다섯 가지 서로 다른 사건의 이름이다.

## 목차

1. [compile-red — 테스트 소스 컴파일 실패](#1-compile-red)
2. [assertion-red — 어서션·오류 실패](#2-assertion-red)
3. [main-compile-broken — 프로덕션 컴파일 실패](#3-main-compile-broken)
4. [infra-red — 환경 문제](#4-infra-red)
5. [no-fresh-results — 아무 일도 없었음](#5-no-fresh-results)
6. [분류 우선순위와 판별 순서](#6-분류-우선순위)
7. [헷갈리기 쉬운 경계 사례](#7-경계-사례)

---

## 1. compile-red

**정당한 RED.** JVM TDD의 첫 사이클은 거의 항상 여기서 시작한다.

### 신호

```
> Task :core:compileTestJava FAILED
/w/core/src/test/java/com/acme/user/UserServiceTest.java:11: error: cannot find symbol
    private UserService service;
            ^
  symbol:   class UserService
  location: class UserServiceTest
```

Kotlin:

```
> Task :core:compileTestKotlin FAILED
e: file:///w/core/src/test/kotlin/com/acme/order/OrderServiceTest.kt:9:23 Unresolved reference: OrderService
```

판별: `compileTestJava|compileTestKotlin ... FAILED` **그리고**
(`cannot find symbol` | `Unresolved reference` | `package ... does not exist`).

### 왜 이게 RED 인가

테스트가 아직 없는 타입을 참조한다는 것은, 그 타입이 있어야 한다는 명세를
컴파일러가 검증하고 실패한 것이다. 이 순간 **컴파일러가 어서션 역할을 한다.**

Gradle은 테스트를 실행하지 못했으므로 `TEST-*.xml` 을 **쓰지 않는다.**
XML만 보는 도구는 여기서 "실패한 테스트 없음 = RED 아님"으로 판정하고,
그러면 첫 사이클에서 영원히 진행할 수 없다. JS/Python용 TDD 가드를 JVM에
그대로 옮기면 정확히 여기서 죽는다.

### 흔한 오류

컴파일이 안 된다고 급히 빈 클래스를 만드는 것. 그건 테스트가 요구하지 않은
프로덕션 편집이고, RED를 지워 버린다. 컴파일 오류를 RED로 인정하고
**의미 있는 최소 구현**으로 바로 넘어가라.

### 추출되는 정보

| 항목 | 출처 |
|---|---|
| 미해결 심볼 | `symbol: class X` (javac), `Unresolved reference: X` (kotlinc) |
| 실패 스위트 | 로그의 `src/test/(java\|kotlin)/.../XxxTest.(java\|kt)` 경로 |

이 심볼 목록이 가드의 스코프 검사에서 "이 파일을 편집해도 되는가"의 근거가 된다.

---

## 2. assertion-red

**정당한 RED.** 테스트가 실행됐고 기대가 어긋났다.

### 신호

`{module}/build/test-results/test/TEST-*.xml` 의
`<testsuite ... failures="N" errors="M">` 에서 `N + M > 0`.

```xml
<testsuite name="com.acme.user.UserServiceTest" tests="3" failures="1" errors="0" ...>
  <testcase name="rejectsUnknownId" classname="com.acme.user.UserServiceTest">
    <failure message="expected UserNotFoundException" type="org.opentest4j.AssertionFailedError">
      at com.acme.user.UserService.findById(UserService.java:41)
      at com.acme.user.UserServiceTest.rejectsUnknownId(UserServiceTest.java:58)
    </failure>
  </testcase>
</testsuite>
```

### failures 와 errors 의 차이

- `failures` — 어서션 실패 (`AssertionFailedError`). 기대와 실제가 다르다.
- `errors` — 예상 못 한 예외로 테스트가 중단됨. `NullPointerException`,
  Spring 컨텍스트 로드 실패 등.

**둘 다 RED로 센다.** `@WebMvcTest` 가 아직 없는 협력자 때문에 컨텍스트를 못
띄우는 것은 `errors` 로 잡히지만, 의미는 "그 협력자를 만들어야 한다"는 정당한 RED다.

### 스택트레이스가 가장 강한 스코프 신호인 이유

스택 프레임은 **실제로 호출된 협력자를 지명한다.** 클래스 이름 유사도나 패키지
일치보다 훨씬 정확하다. `UserServiceTest` 가 실패했는데 트레이스에 `Money` 가
나온다면, `Money` 를 고치는 것도 이 RED가 정당화하는 범위다.

Spring 메시지에 담긴 FQCN도 같은 값어치를 한다:

```
NoSuchBeanDefinitionException: No qualifying bean of type 'com.acme.web.OrderService'
```

여기서 `OrderService` 는 누락된 협력자를 스택트레이스보다 정확히 지목한다.

---

## 3. main-compile-broken

**RED가 아니다.** 프로덕션 소스가 깨졌다.

```
> Task :core:compileJava FAILED
/w/core/src/main/java/com/acme/user/UserService.java:22: error: ';' expected
```

판별: `compileJava|compileKotlin FAILED` — **`compileTest`가 아니다.**

TDD 사이클에서 이 상태는 언제나 사고다. 직전 편집이 문법을 깨뜨렸다.
**되돌린다.** 이 상태에서는 어떤 상태 전이도 일어나지 않으므로,
"고치면서 앞으로 나가는" 경로가 막혀 있다 — 의도된 설계다.

---

## 4. infra-red

**RED가 아니다.** 코드와 무관한 환경 문제다.

| 신호 | 원인 |
|---|---|
| `Could not resolve <dep>` | 저장소 접근 불가, 버전 오타, 오프라인 |
| `Connection refused` | 외부 서비스 미기동 |
| `Could not find or load main class` | 클래스패스 구성 오류 |
| `Docker environment ... not available` | Testcontainers, Docker 미기동 |
| `Cannot find a Java installation ... matching` | 툴체인 미설치 |
| `UnknownHostException` | 네트워크 |

**테스트를 고쳐서 해결하려 들지 마라.** 환경을 고치거나, 그 테스트를 이번
사이클 범위에서 빼라. 여기서 테스트를 완화하면 커버리지가 조용히 사라진다.

---

## 5. no-fresh-results

**아무 일도 일어나지 않았다.**

```
> Task :core:test UP-TO-DATE
BUILD SUCCESSFUL in 421ms
```

Gradle은 입력이 바뀌지 않으면 `test` 를 건너뛰고, 그러면 새 XML이 없다.
상태 머신은 오래된 XML을 mtime 게이트로 걸러내므로 **전이하지 않는다.**
오래된 초록을 재생해 통과한 척하는 것보다 낫다.

```sh
./gradlew :core:test --tests '*Xxx' --rerun-tasks
./gradlew :core:cleanTest :core:test --tests '*Xxx'
```

주의: 직전 실행이 **실패**했다면 태스크는 UP-TO-DATE가 되지 않는다.
빨간 테스트를 남겨 둔 상태에서 UP-TO-DATE를 보는 일은 없다.

---

## 6. 분류 우선순위

XML을 먼저 보고, 없을 때만 로그로 간다.

```
1. run-marker 보다 새로운 TEST-*.xml 이 있는가?
   ├─ 있다 ─ failures + errors > 0  → assertion-red
   │        └ tests > 0, 실패 0     → green
   └─ 없다 ─┐
            ├ compileTest* FAILED + (cannot find symbol | Unresolved reference)
            │                                → compile-red
            ├ compileJava|compileKotlin FAILED (메인)
            │                                → main-compile-broken
            ├ Could not resolve | Connection refused | Docker …
            │                                → infra-red
            └ 그 외                          → no-fresh-results
```

**XML이 로그보다 우선한다.** 로그에는 이전 실행의 잔재가 섞일 수 있지만,
mtime 게이트를 통과한 XML은 이번 실행의 산물임이 보장된다.

---

## 7. 경계 사례

### 컴파일은 되는데 테스트가 0개

```
> Task :core:test
BUILD SUCCESSFUL
```
XML이 없거나 `tests="0"`. 필터가 아무것도 못 잡은 것이다. `--tests` 패턴을 확인하라.
`*UserServiceTest` 와 `UserServiceTest` 는 다르다 (후자는 FQCN 이 아니면 안 잡힌다).

### 어서션은 통과했는데 `errors` 가 있다

`@AfterEach` / `@AfterAll` 에서 던진 예외, 또는 리소스 정리 실패다.
테스트 로직은 맞지만 픽스처가 깨져 있다. RED로 세는 것이 맞다 —
초록 바라고 부를 수 없는 상태다.

### 컴파일 실패인데 `cannot find symbol` 이 없다

문법 오류, import 충돌, 제네릭 불일치 등. 이건 **테스트 코드 자체가 틀린 것**이지
"아직 없는 것을 요구하는" RED가 아니다. 상태 머신은 `no-fresh-results` 로 분류해
전이하지 않는다. 테스트를 고쳐라.

### 병렬 실행에서 일부만 실패

`failures` 합산이 0보다 크면 assertion-red다. 다만 병렬 테스트의 간헐적 실패는
경합 조건일 수 있으므로, 두 번 연속 같은 테스트가 실패하는지 확인하라.
간헐 실패를 RED로 취급하면 존재하지 않는 버그를 쫓게 된다.

### `@Disabled` 로 넘긴 테스트

`skipped` 로 집계되고 `failures`/`errors` 에 들어가지 않는다.
비활성 테스트는 RED를 만들지 못한다 — TDD 사이클에서 `@Disabled` 는
"이 명세를 포기했다"는 뜻이다. 쓰지 마라.
