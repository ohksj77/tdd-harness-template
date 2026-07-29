# Mockito 패턴과 함정

## 기본 배선

```java
@ExtendWith(MockitoExtension.class)
class OrderServiceTest {

    @Mock OrderRepository repository;
    @Mock PaymentGateway gateway;
    @InjectMocks OrderService service;      // 생성자 주입으로 목을 꽂는다

    @Test
    void placesOrder() { ... }
}
```

`@InjectMocks` 는 생성자 주입일 때 가장 예측 가능하다.
필드 주입에 의존하는 클래스라면 그 자체가 설계 냄새다.

명시적 생성이 더 읽히는 경우도 많다:

```java
private final OrderRepository repository = mock(OrderRepository.class);
private final OrderService service = new OrderService(repository);
```

## BDD 스타일을 권한다

```java
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;

given(repository.findById(1L)).willReturn(Optional.of(order));

// when
var result = service.findById(1L);

// then
then(repository).should().findById(1L);
```

`when/thenReturn` 과 섞지 마라. 테스트 안의 `// when` 주석과
Mockito 의 `when(...)` 이 시각적으로 충돌해 읽기 나빠진다.

## strict stub — 기본값을 끄지 마라

`MockitoExtension` 은 기본이 `STRICT_STUBS` 다. 쓰이지 않은 스텁이 있으면 실패한다.

```
UnnecessaryStubbingException: Unnecessary stubbings detected
```

이건 **유용한 실패**다. 두 가지 중 하나를 뜻한다:
① 테스트가 실제로 그 경로를 타지 않는다 (테스트가 틀렸다)
② 스텁이 남은 잔재다 (정리하라)

`@MockitoSettings(strictness = Strictness.LENIENT)` 로 끄고 싶은 충동이 들면,
거의 항상 테스트를 고치는 쪽이 맞다. 정말 필요하면 그 스텁 하나만:

```java
lenient().when(clock.instant()).thenReturn(FIXED);
```

## 인자 매처

```java
given(repository.findById(anyLong())).willReturn(Optional.of(order));
given(repository.save(any(Order.class))).willAnswer(inv -> inv.getArgument(0));
given(gateway.charge(eq(1L), any())).willReturn(APPROVED);
```

**매처와 실제 값을 섞을 수 없다.** 하나라도 매처를 쓰면 전부 매처여야 한다:

```java
given(gateway.charge(1L, any()));        // ✗ InvalidUseOfMatchersException
given(gateway.charge(eq(1L), any()));    // ✓
```

가능하면 **실제 값을 써라.** `any()` 는 "무엇이 넘어가든 상관없다"는 선언이고,
그건 대개 사실이 아니다.

## ArgumentCaptor — 넘긴 값을 검증할 때

```java
@Captor ArgumentCaptor<Order> orderCaptor;

@Test
void savesOrderWithPaidStatus() {
    service.place(request);

    then(repository).should().save(orderCaptor.capture());
    assertThat(orderCaptor.getValue().status()).isEqualTo(PAID);
}
```

캡터가 자주 필요하다면 **반환값으로 관찰할 수 있게 설계를 바꾸는 편**이 낫다.
상태 검증이 상호작용 검증보다 리팩터링에 강하다.

## willAnswer — 인자를 가공해 돌려줄 때

```java
// save 가 id 를 채워 돌려주는 리포지토리 흉내
given(repository.save(any(Order.class))).willAnswer(inv -> {
    Order o = inv.getArgument(0);
    return o.withId(1L);
});
```

## 예외 스텁

```java
given(gateway.charge(anyLong(), any())).willThrow(new GatewayTimeoutException());

// void 메서드
willThrow(new IllegalStateException()).given(publisher).publish(any());
```

## verify 를 절제하라

```java
then(repository).should().save(any());                  // 한 번
then(repository).should(times(2)).save(any());
then(repository).should(never()).delete(any());
then(repository).shouldHaveNoInteractions();
then(repository).should(atLeastOnce()).findById(1L);
```

`verifyNoMoreInteractions` 는 특히 조심하라 — 구현이 협력자를 한 번 더 부르는
순간 깨진다. 그건 대개 검증하고 싶은 계약이 아니다.

**판단 기준:** 이 상호작용이 사라지면 사용자에게 보이는 무언가가 달라지는가?
- 그렇다 → 결과(상태)로 검증할 수 있는지 먼저 보라
- 아니다 → `verify` 를 지워라

`verify` 가 꼭 맞는 경우: 이벤트 발행, 알림 전송, 감사 로그 기록처럼
**부수효과 자체가 계약**인 것들.

## 목으로 만들면 안 되는 것

| 대상 | 대신 |
|---|---|
| 값 객체 (`Money`, `OrderId`) | 진짜를 만든다 |
| 도메인 엔티티 | 진짜를 만든다 (빌더로) |
| DTO / record | 진짜를 만든다 |
| 컬렉션, `Optional` | 진짜를 만든다 |
| 테스트 대상 자신 | 절대. `@Spy` 로 자기 메서드를 스텁하는 건 테스트가 아니다 |
| 내가 소유하지 않은 서드파티 타입 | 얇은 어댑터를 만들고 그 인터페이스를 목으로 |

마지막 항목이 중요하다. 서드파티 클래스를 직접 목으로 만들면, 그 라이브러리가
실제로 어떻게 동작하는지에 대한 **당신의 추측**을 검증하게 된다.

## final 클래스 / static 메서드

Java 의 `final` 클래스와 Kotlin 의 기본 `final` 은 Mockito 5+ 의 인라인
mock-maker 가 처리한다 (기본 활성). 그래도 안 되면:

```
# src/test/resources/mockito-extensions/org.mockito.plugins.MockMaker
mock-maker-inline
```

static 은 `mockStatic` 으로 가능하지만 **거의 항상 잘못된 신호**다:

```java
try (var mocked = mockStatic(Instant.class)) {
    mocked.when(Instant::now).thenReturn(FIXED);
}
```

`Instant.now()` 를 목으로 만들 바에는 `Clock` 을 주입하라.
static 을 목으로 만들어야 한다는 것은 대개 의존성이 숨어 있다는 뜻이다.

## 경계면 함정 — 이 하네스가 특히 경계하는 것

```java
// 작성 시점에는 맞았다
given(repository.findById(1L)).willReturn(Optional.of(order));
```

나중에 `findById` 가 `Optional<Order>` 에서 `Order` 로 바뀌면 컴파일 오류가 나서
잡힌다. 하지만 **오버로드가 추가되거나 파라미터 타입이 넓어지면**
스텁은 계속 컴파일되면서 실제로는 다른 메서드를 스텁하게 된다.
슬라이스 테스트는 초록인 채로 프로덕션이 깨진다.

이게 `tdd-boundary-inspector` 의 1순위 검증 항목인 이유다.
리팩터링으로 시그니처를 건드린 직후에는 반드시 스텁을 실물과 대조하라.
