# 테스트 구조와 픽스처

## 파일 배치

```
src/test/java/com/acme/order/OrderServiceTest.java     # 대상과 같은 패키지
src/test/java/com/acme/order/OrderServiceIT.java       # 통합 테스트
src/testFixtures/java/com/acme/order/OrderFixtures.java # 모듈 간 공유 픽스처
```

같은 패키지에 두면 패키지 프라이빗 멤버에 접근할 수 있고, 무엇보다
테스트가 프로덕션 파일 옆에 있어 함께 유지된다.

접미사 관례:

| 접미사 | 의미 |
|---|---|
| `Test` | 단위·슬라이스 테스트. `test` 태스크가 돈다 |
| `IT` | 통합 테스트. 별도 소스셋/태스크 |
| `Tests` | `Test` 와 같음. **프로젝트에서 하나만 골라 통일하라** |

상태 머신은 `Test`, `Tests`, `IT`, `Spec`, `TestCase` 접미사를 벗겨
프로덕션 클래스 후보를 추정한다 (`UserServiceTest` → `UserService`).
관례를 지키면 가드의 스코프 판정이 정확해진다.

## 픽스처 빌더

```java
public final class OrderFixtures {

    private OrderFixtures() {}

    public static Order.Builder anOrder() {
        return Order.builder()
            .id(1L)
            .status(PENDING)
            .totalAmount(10_000)
            .createdAt(Instant.parse("2026-01-01T00:00:00Z"));
    }

    public static Order paidOrder() {
        return anOrder().status(PAID).build();
    }
}
```

사용:

```java
var order = anOrder().totalAmount(50_000).build();   // 관심 있는 필드만 명시
```

**테스트가 신경 쓰는 값만 테스트에 보이게 한다.** 나머지는 기본값에 숨긴다.
`new Order(1L, "PAID", 12000, null, Instant.now(), false, null)` 같은 호출은
무엇이 이 테스트의 관심사인지 감춘다.

빌더가 없는 레거시 타입이라면 테스트 전용 팩터리 메서드로 감싸라.

## @BeforeEach 를 절제하라

```java
// ✗ 테스트를 읽으려면 위로 스크롤해야 한다
@BeforeEach
void setUp() {
    order = new Order(...);
    user = new User(...);
    given(repository.findById(1L)).willReturn(Optional.of(order));
    given(userRepository.findById(1L)).willReturn(Optional.of(user));
}
```

```java
// ✓ 각 테스트가 자기 맥락을 세운다
@Test
void returnsOrderWhenExists() {
    given(repository.findById(1L)).willReturn(Optional.of(paidOrder()));
    ...
}
```

`@BeforeEach` 에 넣어도 되는 것: 목 생성, 테스트 대상 생성처럼
**모든 테스트가 똑같이 필요로 하는 배선**. 넣지 말 것: 스텁, 데이터.

특히 `@BeforeEach` 에 스텁을 두면 strict stub 이 "안 쓰인 스텁" 으로 실패시킨다 —
Mockito 가 옳다.

## @Nested 로 문맥 나누기

```java
class OrderServiceTest {

    @Nested
    class 주문이_존재할_때 {
        @Test void 주문을_반환한다() { ... }
        @Test void 결제_게이트웨이를_호출하지_않는다() { ... }
    }

    @Nested
    class 주문이_없을_때 {
        @Test void NotFound_예외를_던진다() { ... }
    }
}
```

Java 에서도 밑줄 이름은 유효하다. Kotlin 이면 백틱을 쓴다.
실패 리포트가 `OrderServiceTest > 주문이_없을_때 > NotFound_예외를_던진다` 로 나온다.

바깥 클래스의 `@BeforeEach` 가 안쪽보다 먼저 돈다. 중첩은 2단계까지가 실용적이다.

## 파라미터화를 언제 쓰는가

**쓴다** — 같은 동작, 다른 입력:

```java
@ParameterizedTest(name = "{0}원은 {1} 등급")
@CsvSource({ "1000, BRONZE", "50000, SILVER", "500000, GOLD" })
void assignsGrade(int amount, Grade expected) {
    assertThat(Grade.of(amount)).isEqualTo(expected);
}
```

**쓰지 않는다** — 서로 다른 동작을 억지로 묶는 것:

```java
// ✗ 실패해도 무엇이 깨졌는지 흐려진다
@ParameterizedTest
@MethodSource("allTheCases")
void handlesEverything(Input in, Object expected, boolean shouldThrow) { ... }
```

`shouldThrow` 같은 불리언 파라미터가 등장하면 테스트를 쪼개라는 신호다.

TDD 사이클에서는 **먼저 구체적인 테스트 하나**로 RED를 만들고, 두 번째 사례가
생겼을 때 파라미터화로 합치는 것이 자연스럽다 (삼각측량).

## 테스트가 서로 간섭하지 않게

| 위험 | 대책 |
|---|---|
| `static` 가변 필드 | 쓰지 마라. 꼭 필요하면 `@AfterEach` 에서 되돌린다 |
| 시스템 프로퍼티, 환경 변수 | `@SetSystemProperty` (junit-pioneer) 또는 직접 복원 |
| 파일 시스템 | `@TempDir Path tempDir` |
| DB 상태 | `@DataJpaTest` 는 롤백. `@SpringBootTest` 는 직접 정리 |
| 실행 순서 의존 | `@Order` 를 쓰고 있다면 이미 잘못됐다 |
| 시각 | `Clock` 주입 + `Clock.fixed` |

```java
@Test
void writesReport(@TempDir Path tempDir) throws Exception {
    var out = tempDir.resolve("report.csv");
    exporter.export(orders, out);
    assertThat(out).content().startsWith("id,status");
}
```

## 테스트 코드도 리팩터링 대상이다

중복된 어서션 블록, 반복되는 스텁 배선은 추출해도 된다 —
`tdd-refactorer` 의 정당한 작업 범위다.

단 **어서션 자체는 건드리지 않는다.** 어서션은 명세이고,
명세를 바꾸는 것은 리팩터링이 아니라 동작 변경이다.

추출할 때 조심할 것: 헬퍼가 어서션을 감싸면 실패 위치가 헬퍼로 잡혀
어느 테스트가 깨졌는지 보기 어려워진다. AssertJ 를 쓴다면
`assertThat(...).as("주문 상태").isEqualTo(...)` 로 설명을 붙여 두라.

## 테스트가 길어질 때

한 테스트가 20줄을 넘으면 대개 셋 중 하나다:

1. **픽스처 준비가 길다** → 빌더로 추출
2. **여러 동작을 한 번에 본다** → 테스트를 쪼갠다
3. **대상 클래스의 협력자가 너무 많다** → 프로덕션 설계를 쪼갠다

3번은 TDD가 주는 가장 값진 신호다. 테스트가 쓰기 어려우면
설계가 잘못된 것이지 테스트 도구가 부족한 게 아니다.
