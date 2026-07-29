# 리팩터링 카탈로그 — 냄새, 동작, 검증 시점

각 항목은 **한 동작 → 한 실행** 리듬을 전제한다.

## 목차

1. [이름 변경](#이름-변경)
2. [메서드 추출](#메서드-추출)
3. [값 객체 도입](#값-객체-도입)
4. [파라미터 객체 도입](#파라미터-객체-도입)
5. [조건문 정리](#조건문-정리)
6. [메서드·필드 이동](#메서드필드-이동)
7. [클래스 분리](#클래스-분리)
8. [테스트 코드 리팩터링](#테스트-코드-리팩터링)

---

## 이름 변경

가장 값싸고 가장 효과가 크다. 의심스러우면 먼저 하라.

```java
// 이름이 거짓말을 한다
public List<Order> getOrders(Long id)     // 사실은 사용자의 미결제 주문만
public List<Order> findUnpaidOrdersOf(Long userId)
```

**IDE의 rename 기능을 쓴다.** 문자열 치환은 문자열 리터럴·주석·리플렉션 참조를
건드려 조용히 깨뜨린다.

검증: 이름 변경 하나마다 실행할 필요는 없다. 관련된 이름 묶음을 한 번에 바꾸고
실행하는 것이 실용적이다. 단 **컴파일이 통과하는 단위**를 지켜라.

주의: 공개 API 이름은 계약이다. `_workspace/02_designer_contract.md` 에 있는
이름을 바꾸려면 계약 변경이므로 리팩터링 범위 밖이다.

---

## 메서드 추출

```java
// 주석으로 단락을 나누고 있다면 그 단락이 메서드다
public Order place(OrderRequest request) {
    // 검증
    if (request.items().isEmpty()) throw new EmptyOrderException();
    if (request.totalAmount() <= 0) throw new InvalidAmountException();

    // 재고 차감
    for (var item : request.items()) {
        inventory.reserve(item.sku(), item.quantity());
    }
    ...
}
```

```java
public Order place(OrderRequest request) {
    validate(request);
    reserveInventory(request.items());
    ...
}
```

**추출한 메서드의 이름이 "무엇을"을 말해야 한다.** `doStep2` 같은 이름이라면
추출할 준비가 안 된 것이다.

검증: 추출마다 실행한다. 가장 흔한 실수는 추출 과정에서 변수 스코프가 바뀌어
동작이 미묘하게 달라지는 것이다.

**역방향(인라인)도 리팩터링이다.** 한 번만 쓰이고 이름이 본문보다 길면 인라인하라.

---

## 값 객체 도입

원시 타입 집착의 해결책. 검증 규칙이 여러 곳에 흩어질 때가 신호다.

```java
// 검증이 호출부마다 반복된다
public void charge(long amount) {
    if (amount <= 0) throw new IllegalArgumentException();
    ...
}
```

```java
public record Money(long amount) {
    public Money {
        if (amount <= 0) throw new IllegalArgumentException("금액은 양수여야 합니다: " + amount);
    }
    public Money plus(Money other) { return new Money(amount + other.amount); }
}
```

단계적으로 한다 — 한 번에 전부 바꾸지 마라:

```
1. 값 객체 클래스를 만든다 (테스트는 아직 안 건드린다)  → 실행
2. 가장 안쪽 한 곳에서만 쓴다                          → 실행
3. 경계에서 변환한다                                   → 실행
4. 나머지 호출부를 옮긴다                              → 실행
```

Kotlin 이면 `@JvmInline value class` 로 런타임 비용 없이 만들 수 있다.

---

## 파라미터 객체 도입

파라미터가 4개를 넘고 늘 함께 다니면.

```java
public Order create(Long userId, String sku, int quantity, String couponCode, boolean express)
public Order create(OrderRequest request)
```

같은 파라미터 조합이 여러 메서드에 반복된다면 그건 이미 객체다.

Java 라면 `record` 가 가장 짧다. Kotlin 이면 `data class`.

---

## 조건문 정리

### 가드 절 — 중첩을 평평하게

```java
// ✗
public Order find(Long id) {
    if (id != null) {
        var order = repository.findById(id);
        if (order.isPresent()) {
            if (order.get().isVisible()) {
                return order.get();
            } else { throw new HiddenOrderException(); }
        } else { throw new OrderNotFoundException(id); }
    } else { throw new IllegalArgumentException(); }
}
```

```java
// ✓
public Order find(Long id) {
    if (id == null) throw new IllegalArgumentException("id 는 필수입니다");
    var order = repository.findById(id).orElseThrow(() -> new OrderNotFoundException(id));
    if (!order.isVisible()) throw new HiddenOrderException();
    return order;
}
```

### 타입 분기 → 다형성

```java
// ✗ 새 타입이 생길 때마다 여기를 고쳐야 한다
switch (order.type()) {
    case NORMAL  -> normalFee(order);
    case EXPRESS -> expressFee(order);
    case GIFT    -> giftFee(order);
}
```

```java
// ✓ 타입이 자기 규칙을 안다
public enum OrderType {
    NORMAL  { public long fee(Order o) { return o.amount() / 100; } },
    EXPRESS { public long fee(Order o) { return o.amount() / 50; } },
    GIFT    { public long fee(Order o) { return 0; } };

    public abstract long fee(Order o);
}
```

이건 큰 동작이다. 사이클 하나를 쓸 각오를 하고, 분기 하나씩 옮기며 매번 실행하라.

**주의:** 분기가 2개뿐이고 늘어날 조짐이 없으면 그냥 두는 편이 낫다.
다형성은 공짜가 아니다.

---

## 메서드·필드 이동

기능 편애 — 자기 데이터보다 남의 데이터를 더 많이 만지는 메서드.

```java
// OrderService 안에 있지만 Order 의 데이터만 만진다
public boolean isRefundable(Order order) {
    return order.status() == PAID
        && order.paidAt().isAfter(Instant.now().minus(7, DAYS));
}
```

→ `Order.isRefundable(Clock clock)` 으로 옮긴다.
(시각 의존을 `Clock` 주입으로 함께 정리한다 — 그래야 테스트가 결정적이 된다.)

순서: ① 새 위치에 메서드를 만든다 → 실행 ② 옛 메서드가 위임하게 한다 → 실행
③ 호출부를 옮긴다 → 실행 ④ 옛 메서드를 지운다 → 실행

---

## 클래스 분리

한 클래스가 두 가지 이유로 변경된다면 둘이어야 한다.

신호: 필드의 절반은 A 메서드들만 쓰고 나머지 절반은 B 메서드들만 쓴다.
테스트에서 목이 5개를 넘는다.

이건 사이클 하나를 통째로 쓰는 동작이다. 리팩터링 창 안에서 하되,
중간에 예산이 소진되면 **초록으로 마감하고 다음 사이클로 이어가라.**
반쯤 분리된 상태로 방치하는 것이 최악이다.

---

## 테스트 코드 리팩터링

정당한 범위다. 단 경계가 있다.

| 해도 되는 것 | 하면 안 되는 것 |
|---|---|
| 픽스처 생성을 빌더로 추출 | **어서션 변경** |
| 반복되는 스텁 배선을 헬퍼로 | 테스트 삭제 |
| `@Nested` 로 문맥 정리 | `@Disabled` 추가 |
| 테스트 이름 개선 | 검증 범위 축소 |

어서션은 명세다. 명세를 바꾸는 것은 리팩터링이 아니라 동작 변경이다.

어서션을 헬퍼로 감쌀 때는 실패 위치가 헬퍼로 잡혀 어느 테스트가 깨졌는지
보기 어려워진다. AssertJ 의 `.as("설명")` 을 붙여 두라.

---

## 검증 빈도 요약

| 동작 | 실행 시점 |
|---|---|
| 이름 변경 (IDE) | 묶음 단위로 한 번 |
| 메서드 추출/인라인 | 매번 |
| 값 객체 도입 | 각 단계마다 |
| 메서드 이동 | 각 단계마다 |
| 조건문 → 다형성 | 분기 하나 옮길 때마다 |
| 클래스 분리 | 자주. 최소한 필드 이동마다 |

의심스러우면 더 자주 실행하라. `--tests` 로 좁히면 몇 초다.
