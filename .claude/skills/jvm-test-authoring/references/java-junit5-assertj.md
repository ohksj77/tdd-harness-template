# Java + JUnit 5 + AssertJ

## 의존성 (Gradle Kotlin DSL)

```kotlin
dependencies {
    testImplementation(platform("org.junit:junit-bom:5.11.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testImplementation("org.assertj:assertj-core:3.26.3")
    testImplementation("org.mockito:mockito-core:5.14.2")
    testImplementation("org.mockito:mockito-junit-jupiter:5.14.2")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test { useJUnitPlatform() }
```

Spring Boot 프로젝트라면 `spring-boot-starter-test` 가 위 전부를 포함한다.
버전을 직접 고정하지 말고 스타터에 맡겨라.

## 표준 임포트

```java
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.SoftAssertions.assertSoftly;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.mockito.ArgumentMatchers.any;
```

테스트 클래스와 메서드는 `public` 이 필요 없다 (JUnit 5).
패키지 프라이빗이 관례다.

## 라이프사이클

| 애노테이션 | 시점 |
|---|---|
| `@BeforeEach` / `@AfterEach` | 각 테스트 |
| `@BeforeAll` / `@AfterAll` | 클래스당 한 번 (`static`, 또는 `@TestInstance(PER_CLASS)`) |
| `@Nested` | 중첩 컨텍스트. 바깥 `@BeforeEach` 가 먼저 돈다 |

`@BeforeEach` 에 픽스처를 쌓는 것을 절제하라. 테스트를 읽을 때
위로 스크롤해야 한다면 이미 과하다.

## 예외 검증

```java
assertThatThrownBy(() -> service.findById(9L))
    .isInstanceOf(UserNotFoundException.class)
    .hasMessageContaining("9")
    .hasNoCause();

// 예외가 나지 않아야 할 때
assertThatCode(() -> service.findById(1L)).doesNotThrowAnyException();

// 예외 객체 자체를 더 보고 싶을 때
var thrown = catchThrowableOfType(() -> service.findById(9L), UserNotFoundException.class);
assertThat(thrown.getUserId()).isEqualTo(9L);
```

`assertThrows` (JUnit) 보다 `assertThatThrownBy` (AssertJ) 를 쓰면
메시지·원인·필드까지 체인으로 이어 검증할 수 있다.

## 컬렉션

```java
assertThat(orders).hasSize(2);
assertThat(orders).containsExactly(a, b);              // 순서 포함
assertThat(orders).containsExactlyInAnyOrder(b, a);    // 순서 무관
assertThat(orders).extracting(Order::status).containsOnly(PAID);
assertThat(orders).extracting("status", "totalAmount")
                  .containsExactly(tuple(PAID, 12_000));
assertThat(orders).filteredOn(o -> o.amount() > 10_000).hasSize(1);
assertThat(orders).allSatisfy(o -> assertThat(o.id()).isNotNull());
assertThat(orders).isSortedAccordingTo(comparing(Order::createdAt));
```

## 객체 비교

```java
// equals 를 구현하지 않은 객체를 필드 단위로 비교
assertThat(actual).usingRecursiveComparison()
    .ignoringFields("id", "createdAt")
    .isEqualTo(expected);

// 특정 타입만 느슨하게
assertThat(actual).usingRecursiveComparison()
    .withComparatorForType(BigDecimal::compareTo, BigDecimal.class)
    .isEqualTo(expected);
```

`BigDecimal` 비교는 반드시 `usingComparator(BigDecimal::compareTo)` 또는
`isEqualByComparingTo` 를 써라. `equals` 는 스케일까지 본다
(`1.0` != `1.00`) — 금액 테스트가 이유 없이 빨개지는 단골 원인이다.

```java
assertThat(price).isEqualByComparingTo("12000.00");
```

## Optional

```java
assertThat(repository.findById(1L)).isPresent().get()
    .extracting(User::name).isEqualTo("kim");

assertThat(repository.findById(9L)).isEmpty();
```

## 소프트 어서션

여러 단언을 한 번에 확인하고 싶을 때. 첫 실패에서 멈추지 않는다.

```java
assertSoftly(softly -> {
    softly.assertThat(order.status()).isEqualTo(PAID);
    softly.assertThat(order.totalAmount()).isEqualTo(12_000);
    softly.assertThat(order.paidAt()).isNotNull();
});
```

TDD 사이클 중에는 오히려 **쓰지 않는 편이 낫다** — 한 번에 하나씩 통과시키는
리듬이 흐려진다. 회귀 테스트나 마감 검증에서 유용하다.

## 파라미터화

```java
@ParameterizedTest
@ValueSource(ints = {0, -1, -100})
void rejectsNonPositiveAmount(int amount) {
    assertThatThrownBy(() -> new Money(amount))
        .isInstanceOf(IllegalArgumentException.class);
}

@ParameterizedTest(name = "{0}원 → {1}등급")
@CsvSource({
    "1000, BRONZE",
    "50000, SILVER",
    "500000, GOLD",
})
void assignsGradeByAmount(int amount, Grade expected) {
    assertThat(Grade.of(amount)).isEqualTo(expected);
}

@ParameterizedTest
@MethodSource("invalidOrders")
void rejectsInvalidOrders(Order order, String reason) { ... }

static Stream<Arguments> invalidOrders() {
    return Stream.of(
        arguments(orderWith(null), "상품 없음"),
        arguments(orderWith(0),    "수량 0")
    );
}
```

파라미터화는 **같은 동작의 여러 사례**를 묶을 때 쓴다.
서로 다른 동작을 하나로 묶으면 실패했을 때 무엇이 깨졌는지 흐려진다.

## @Nested 로 문맥 나누기

```java
class OrderServiceTest {

    @Nested
    class WhenOrderExists {
        @BeforeEach void setUp() { given(repository.findById(1L)).willReturn(Optional.of(order)); }

        @Test void returnsOrder() { ... }
        @Test void doesNotCallPaymentGateway() { ... }
    }

    @Nested
    class WhenOrderIsMissing {
        @BeforeEach void setUp() { given(repository.findById(9L)).willReturn(Optional.empty()); }

        @Test void throwsNotFound() { ... }
    }
}
```

실패 리포트에 `OrderServiceTest > WhenOrderIsMissing > throwsNotFound` 로 나온다.

## 하지 말 것

| 금지 | 이유 |
|---|---|
| `@Disabled` | 비활성 테스트는 RED를 만들지 못한다. TDD에서는 "명세 포기" 선언이다 |
| `Thread.sleep` | 느리고 간헐 실패를 만든다. Awaitility 나 결정적 설계를 써라 |
| `@Order` 로 실행 순서 의존 | 테스트 간 결합. 각 테스트는 독립이어야 한다 |
| `System.out.println` 으로 확인 | 어서션으로 표현하라 |
| `catch` 로 예외를 삼키고 `fail()` | `assertThatThrownBy` 를 써라 |
