# Kotlin 관용구로 옮기기

Java 스타일로 쓰인 Kotlin을 Kotlin답게 만드는 리팩터링. 전부 동작 불변이어야 하며,
매 동작마다 테스트를 돌린다.

## data class

```kotlin
// ✗ Java 습관
class OrderResponse(val id: Long, val status: String) {
    override fun equals(other: Any?): Boolean { ... }
    override fun hashCode(): Int { ... }
    override fun toString(): String { ... }
}

// ✓
data class OrderResponse(val id: Long, val status: String)
```

**주의:** `equals` 가 생기면 컬렉션 동작과 어서션 결과가 바뀔 수 있다.
지금까지 참조 동등성에 의존하던 테스트가 있으면 초록이 바뀐다 — 그건
동작 변경이므로, 그런 테스트가 있는지 먼저 확인하라.

## value class — 원시 타입 집착 해소를 공짜로

```kotlin
@JvmInline
value class OrderId(val value: Long) {
    init { require(value > 0) { "OrderId 는 양수여야 합니다: $value" } }
}
```

런타임에는 `Long` 그대로라 박싱 비용이 없다.
Java 상호운용이 필요한 경계에서는 실제로 래핑되므로, 공개 API 에 쓸 때는
Java 호출부에서 어떻게 보이는지 확인하라.

## sealed — 타입 분기를 컴파일러가 검사하게

```kotlin
sealed interface PaymentResult {
    data class Approved(val transactionId: String) : PaymentResult
    data class Declined(val reason: String) : PaymentResult
    data object Pending : PaymentResult
}

when (result) {                       // else 가 필요 없다
    is PaymentResult.Approved -> markPaid(result.transactionId)
    is PaymentResult.Declined -> markFailed(result.reason)
    PaymentResult.Pending     -> scheduleRetry()
}
```

새 변형을 추가하면 모든 `when` 이 컴파일 오류가 난다 — 놓치는 분기가 없다.
enum 이 상태만 가질 때, sealed 는 변형마다 다른 데이터를 가질 때 쓴다.

## null 안정성 — 방어 코드를 걷어낸다

```kotlin
// ✗ Java 에서 옮겨온 방어 코드
fun process(order: Order?) {
    if (order == null) return
    if (order.items == null) return
    ...
}

// ✓ 타입으로 표현한다
fun process(order: Order) { ... }
```

```kotlin
// nullable 이 진짜 계약인 곳에서는 관용구를 쓴다
val name = user?.profile?.name ?: "익명"
user?.let { notify(it) }
val order = repository.findById(id) ?: throw OrderNotFoundException(id)
```

`!!` 는 리팩터링으로 없애야 할 대상이다. 남아 있다면 타입 설계가 덜 된 것이다.

## 표준 라이브러리로 루프 대체

```kotlin
// ✗
val paid = mutableListOf<Order>()
for (o in orders) { if (o.status == PAID) paid.add(o) }

// ✓
val paid = orders.filter { it.status == PAID }
```

```kotlin
orders.map { it.totalAmount }.sum()
orders.groupBy { it.status }
orders.sortedByDescending { it.createdAt }
orders.firstOrNull { it.id == id }
orders.partition { it.status == PAID }
orders.sumOf { it.totalAmount }
orders.associateBy { it.id }
```

**주의:** 체인이 길어지면 중간 컬렉션이 매번 생긴다. 큰 컬렉션이면 `asSequence()` 를
고려하되, 그건 성능 최적화이지 리팩터링이 아니다 — 측정 없이 하지 마라.

## 확장 함수 — 남의 타입에 어울리는 동작

```kotlin
fun Order.isRefundable(clock: Clock): Boolean =
    status == PAID && paidAt.isAfter(Instant.now(clock).minus(7, ChronoUnit.DAYS))
```

기능 편애를 해소하는 Kotlin식 수단. 단 **남발하면 동작이 흩어진다** —
그 타입을 소유하고 있다면 그냥 멤버 함수로 넣어라.

## scope 함수 — 절제해서

| 함수 | 쓸 때 |
|---|---|
| `let` | nullable 처리, 지역 이름 붙이기 |
| `apply` | 객체 초기화 (빌더 대체) |
| `also` | 부수효과 (로깅) — 체인을 끊지 않고 |
| `run` | 여러 문장의 결과 계산 |
| `with` | 같은 객체의 여러 멤버 접근 |

```kotlin
val order = Order().apply {
    id = 1L
    status = PAID
}
```

중첩된 scope 함수는 `it` 이 무엇을 가리키는지 알 수 없게 만든다.
**두 단계를 넘기면 이름 있는 지역 변수를 써라.**

## 기본 인자로 오버로드 제거

```kotlin
// ✗
fun find(id: Long) = find(id, false)
fun find(id: Long, includeDeleted: Boolean) { ... }

// ✓
fun find(id: Long, includeDeleted: Boolean = false) { ... }
```

Java 에서도 호출해야 한다면 `@JvmOverloads` 를 붙인다.

## 표현식 본문

```kotlin
fun total(): Long = items.sumOf { it.price }
```

한 표현식으로 끝나는 함수에만 쓴다. 여러 줄을 `run { }` 으로 억지로 우겨넣지 마라.

## 리팩터링 순서 제안

```
1. 방어적 null 검사 제거 (타입으로 옮기기)     → 실행
2. 루프 → 표준 라이브러리                      → 실행
3. class → data class                        → 실행 (equals 영향 확인)
4. 원시 타입 → value class                    → 단계마다 실행
5. enum + when → sealed                       → 분기마다 실행
```

3번과 5번은 동작이 바뀔 수 있는 구간이다. 초록이 유지되는지 특히 주의해서 보라.
