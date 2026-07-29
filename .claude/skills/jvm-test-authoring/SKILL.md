---
name: jvm-test-authoring
description: "Java·Kotlin 백엔드에서 JUnit 5 + AssertJ + Mockito 로 실패하는 테스트를 작성하는 방법. 테스트 이름 짓기, Given/When/Then 구조, 어서션 선택, 예외 검증, @Nested·@ParameterizedTest, 목과 스텁을 언제 쓰고 언제 쓰지 말지, 테스트 픽스처와 빌더, Kotlin 백틱 이름과 mockito-kotlin 에 사용. 테스트를 새로 쓰거나 고칠 때 반드시 참조. 테스트 다시 써줘, 어서션 바꿔줘, 이 테스트 왜 이상하냐 같은 후속 요청에도 사용."
---

# JVM 테스트 작성

목표는 테스트 파일이 아니라 **의도한 이유로 실패하는 테스트**다.
틀린 이유로 빨간 테스트는 RED가 아니라 잡음이다.

## 1. 테스트는 명세다 — 이름부터

```java
// ✗ 무엇을 보장하는지 알 수 없다
@Test void testFindById() { }
@Test void test1() { }

// ✓ 이름만 읽고 계약을 알 수 있다
@Test void returnsUserWhenIdExists() { }
@Test void throwsUserNotFoundWhenIdIsUnknown() { }
@Test void rejectsNegativeAmount() { }
```

Kotlin은 백틱으로 문장을 쓸 수 있다:

```kotlin
@Test fun `알 수 없는 ID 면 UserNotFoundException 을 던진다`() { }
```

실패 리포트에 그대로 뜨므로, 이름이 좋으면 스택트레이스를 읽기 전에
무엇이 깨졌는지 알 수 있다.

## 2. 구조: Given / When / Then

```java
@Test
void throwsUserNotFoundWhenIdIsUnknown() {
    // given
    given(repository.findById(9L)).willReturn(Optional.empty());

    // when / then
    assertThatThrownBy(() -> service.findById(9L))
        .isInstanceOf(UserNotFoundException.class)
        .hasMessageContaining("9");
}
```

한 테스트에 `when` 이 두 개면 테스트가 두 개여야 한다.

## 3. 한 번에 하나의 새 동작

RED는 **하나의 새 구현**만 요구해야 한다. "이 테스트를 통과시키려면 두 가지를
만들어야 한다"면 사이클이 너무 넓다.

어서션이 여러 개인 것 자체는 문제가 아니다 — **같은 동작의 여러 측면**을 볼 때는
오히려 낫다:

```java
assertThat(order)
    .extracting(Order::status, Order::totalAmount)
    .containsExactly(PAID, 12_000);
```

문제는 서로 다른 동작을 한 테스트에 몰아넣는 것이다.

## 4. AssertJ — 실패 메시지가 좋은 쪽을 고른다

```java
// ✗ "expected: true but was: false" — 무엇이 왜 틀렸는지 알 수 없다
assertThat(orders.contains(order)).isTrue();

// ✓ 실제 컬렉션 내용을 보여준다
assertThat(orders).contains(order);

// ✗
assertThat(name.startsWith("kim")).isTrue();
// ✓
assertThat(name).startsWith("kim");
```

자주 쓰는 것들:

| 목적 | 표현 |
|---|---|
| 컬렉션 내용 | `.containsExactly(...)`, `.containsExactlyInAnyOrder(...)` |
| 필드 추출 | `.extracting(Order::status)`, `.extracting("status", "amount")` |
| 부분 비교 | `.usingRecursiveComparison().ignoringFields("id", "createdAt")` |
| 예외 | `assertThatThrownBy(...)`, `assertThatCode(...).doesNotThrowAnyException()` |
| Optional | `.isPresent()`, `.hasValue(x)`, `.isEmpty()` |
| 여러 단언 모두 확인 | `assertSoftly(softly -> { ... })` |

**`assertEquals` 보다 `assertThat` 을 쓴다.** 인자 순서를 헷갈릴 일이 없고
실패 메시지가 훨씬 낫다.

## 5. 목은 최소로

목은 **역할 경계**에서만 쓴다. 값 객체나 순수 함수를 목으로 만들지 마라.

| 대상 | 목을 쓰는가 |
|---|---|
| 리포지토리, 외부 클라이언트, 메시지 발행자 | 쓴다 |
| 시간, 랜덤 (`Clock`, `IdGenerator`) | 쓴다 (또는 고정값 주입) |
| 값 객체 (`Money`, `OrderId`) | **쓰지 않는다** — 진짜를 만든다 |
| 도메인 엔티티 | **쓰지 않는다** |
| 테스트 대상 자신 | **절대 쓰지 않는다** |

목이 5개를 넘어가면 대상 클래스의 책임이 너무 많다는 신호다.
목을 늘리지 말고 설계를 쪼개라 — 그 신호를 잡는 것도 TDD의 값어치다.

## 6. 상태를 검증하고, 꼭 필요할 때만 상호작용을 검증한다

```java
// ✓ 결과(상태)를 본다 — 구현이 바뀌어도 살아남는다
assertThat(service.place(order).status()).isEqualTo(PAID);

// △ 상호작용을 본다 — 관찰 가능한 결과가 없을 때만
verify(eventPublisher).publish(any(OrderPlacedEvent.class));
```

`verify` 를 남발하면 테스트가 구현을 그대로 베낀 사본이 되고, 리팩터링할 때마다
깨진다. 그러면 안전망이어야 할 테스트가 족쇄가 된다.

## 7. 픽스처는 빌더로

```java
private Order paidOrder() {
    return Order.builder().id(1L).status(PAID).totalAmount(12_000).build();
}
```

`@BeforeEach` 에 공유 상태를 쌓지 마라. 테스트가 서로에게 의존하게 되고
실행 순서에 따라 결과가 달라진다. **각 테스트가 자기 데이터를 만든다.**

## 8. 시간과 랜덤을 고정한다

```java
Clock clock = Clock.fixed(Instant.parse("2026-07-29T00:00:00Z"), ZoneOffset.UTC);
```

`Instant.now()` 나 `UUID.randomUUID()` 가 어서션에 관여하면 간헐 실패가 생기고,
간헐 실패는 RED 신호 자체를 못 믿게 만든다. 그 순간 하네스는 무의미해진다.

## 9. 컴파일되지 않는 테스트를 두려워 마라

```java
var service = new UserService(repository);   // UserService 가 아직 없다
```

이건 실수가 아니라 **첫 RED** 다. 컴파일러가 어서션 역할을 하고 있다.
빈 클래스를 급히 만들어 컴파일을 통과시키지 마라 — 그건 프로덕션 편집이고
RED를 지우는 행위다. `gradle-test-execution` 의 실패 분류표를 보라.

## 더 읽기

- Java 상세: [references/java-junit5-assertj.md](references/java-junit5-assertj.md)
- Kotlin 상세: [references/kotlin-junit5-assertj.md](references/kotlin-junit5-assertj.md)
- Mockito 패턴과 함정: [references/mockito-patterns.md](references/mockito-patterns.md)
- 구조·픽스처·파라미터화: [references/test-structure-and-fixtures.md](references/test-structure-and-fixtures.md)
- 슬라이스 선택: `spring-test-slice-selection` 스킬
