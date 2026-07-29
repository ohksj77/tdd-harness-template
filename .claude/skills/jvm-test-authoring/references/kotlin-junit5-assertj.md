# Kotlin + JUnit 5 + AssertJ

Java 문서의 내용이 전부 적용된다. 여기는 Kotlin 특유의 차이만 다룬다.

## 의존성

```kotlin
dependencies {
    testImplementation(platform("org.junit:junit-bom:5.11.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testImplementation("org.assertj:assertj-core:3.26.3")
    testImplementation("org.mockito:mockito-core:5.14.2")
    testImplementation("org.mockito:mockito-junit-jupiter:5.14.2")
    testImplementation("org.mockito.kotlin:mockito-kotlin:5.4.0")   // 권장
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}
```

## 백틱 테스트 이름

```kotlin
class UserServiceTest {

    @Test
    fun `존재하는 ID 면 사용자를 반환한다`() { ... }

    @Test
    fun `알 수 없는 ID 면 UserNotFoundException 을 던진다`() { ... }
}
```

Java 식별자 규칙을 벗어난 이름을 쓸 수 있으므로 **명세를 그대로 문장으로** 적는다.
Kotlin 테스트에서는 이게 관례다.

주의: 백틱 이름에 `.` 을 넣으면 `--tests` 필터가 메서드 구분자와 헷갈린다.
마침표는 쓰지 마라.

## `assertThrows` 대신

Kotlin에서는 람다가 자연스러워 AssertJ가 여전히 편하다:

```kotlin
assertThatThrownBy { service.findById(9L) }
    .isInstanceOf(UserNotFoundException::class.java)
    .hasMessageContaining("9")
```

`::class.java` 를 잊지 마라 — AssertJ 는 Java `Class` 를 받는다.

kotlin.test 를 쓴다면:

```kotlin
val ex = assertFailsWith<UserNotFoundException> { service.findById(9L) }
assertThat(ex.userId).isEqualTo(9L)
```

**둘을 섞지 마라.** 프로젝트에서 하나를 골라 일관되게 쓴다.
AssertJ 를 쓰는 프로젝트라면 AssertJ 로 통일하는 편이 실패 메시지가 낫다.

## null 안정성이 테스트를 바꾼다

```kotlin
// Kotlin 에서 non-null 타입은 컴파일러가 이미 보장한다.
// null 검사 테스트를 쓰는 것은 대부분 낭비다.
assertThat(user.name).isNotNull()   // ✗ 타입이 String 이면 의미 없다

// 검증할 가치가 있는 것은 nullable 계약 쪽이다
assertThat(repository.findByEmail("none@x.com")).isNull()
```

플랫폼 타입(Java 상호운용)에서 넘어오는 값은 예외다 — 거기는 검증할 가치가 있다.

## data class 와 비교

```kotlin
data class OrderResponse(val id: Long, val status: String, val amount: Int)

// equals 가 자동 생성되므로 그냥 비교하면 된다
assertThat(actual).isEqualTo(OrderResponse(1L, "PAID", 12_000))
```

`usingRecursiveComparison` 이 필요한 경우가 Java보다 훨씬 적다.
data class 를 쓰면 어서션이 짧아진다.

일부 필드를 무시해야 하면:

```kotlin
assertThat(actual).usingRecursiveComparison()
    .ignoringFields("createdAt")
    .isEqualTo(expected)
```

## mockito-kotlin

Kotlin 에서 순수 Mockito 를 쓰면 `any()` 가 null 을 반환해
non-null 파라미터에서 터진다. `mockito-kotlin` 이 이를 해결한다.

```kotlin
import org.mockito.kotlin.any
import org.mockito.kotlin.given
import org.mockito.kotlin.mock
import org.mockito.kotlin.verify

class OrderServiceTest {

    private val repository = mock<OrderRepository>()
    private val service = OrderService(repository)

    @Test
    fun `주문을 저장한다`() {
        given(repository.save(any())).willAnswer { it.arguments[0] }

        val saved = service.place(order)

        assertThat(saved.status).isEqualTo(OrderStatus.PAID)
        verify(repository).save(any())
    }
}
```

## final 클래스 문제

Kotlin 클래스는 기본이 `final` 이라 Mockito 가 목으로 만들 수 없다.

해결 순서:

1. **인터페이스를 목으로 만든다** — 대부분 여기서 끝난다. Spring 리포지토리는
   이미 인터페이스다.
2. `mockito-inline` 을 쓴다 (Mockito 5+ 는 기본 포함):
   ```
   # src/test/resources/mockito-extensions/org.mockito.plugins.MockMaker
   mock-maker-inline
   ```
3. Spring 프로젝트면 `kotlin-allopen` 플러그인이 `@Component` 등을 열어 준다.
4. 클래스를 `open` 으로 여는 것은 **마지막 수단**이다 — 테스트 편의를 위해
   프로덕션 설계를 바꾸는 것이니, 그 전에 1번을 다시 검토하라.

## MockK

Kotlin 전용 목 라이브러리. coroutine, 확장 함수, object, final 클래스를 모두 다룬다.

```kotlin
val repository = mockk<OrderRepository>()
every { repository.findById(1L) } returns order
verify { repository.findById(1L) }
coEvery { client.fetch(any()) } returns response   // suspend 함수
```

**프로젝트에서 Mockito 와 MockK 를 섞지 마라.** 이 하네스는 Java·Kotlin 공용을
전제로 Mockito(+mockito-kotlin) 를 기본으로 삼는다. 순수 Kotlin + coroutine 중심
프로젝트라면 MockK 로 통일하는 편이 낫다.

## coroutine 테스트

```kotlin
@Test
fun `비동기로 주문을 조회한다`() = runTest {
    coEvery { repository.findById(1L) } returns order

    val result = service.findById(1L)

    assertThat(result.status).isEqualTo(OrderStatus.PAID)
}
```

`kotlinx-coroutines-test` 의 `runTest` 를 쓴다. `runBlocking` 은 가상 시간을
쓰지 않아 delay 가 실제로 걸린다 — 테스트가 느려진다.

## 컴파일 실패 메시지 읽기

Kotlin 의 첫 RED 는 이렇게 생겼다:

```
e: file:///w/core/src/test/kotlin/com/acme/order/OrderServiceTest.kt:9:23 Unresolved reference: OrderService
```

javac 의 `cannot find symbol` 에 해당한다. **정당한 RED** 이며,
상태 머신도 이걸 `compile-red` 로 인식한다.
