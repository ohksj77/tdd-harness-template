# 슬라이스 카탈로그와 안티패턴

## 목차

1. [@WebMvcTest](#webmvctest)
2. [@DataJpaTest](#datajpatest)
3. [@JsonTest](#jsontest)
4. [@RestClientTest](#restclienttest)
5. [@DataRedisTest](#dataredistest)
6. [@SpringBootTest](#springboottest)
7. [컨텍스트 캐시 — 느림의 진짜 원인](#컨텍스트-캐시)
8. [안티패턴 모음](#안티패턴)

---

## @WebMvcTest

웹 계층만 띄운다. 컨트롤러, `@ControllerAdvice`, 컨버터, 필터, 검증.
서비스·리포지토리·`@Component` 는 **뜨지 않는다** — 목으로 넣어야 한다.

```java
@WebMvcTest(OrderController.class)
class OrderControllerTest {

    @Autowired MockMvc mockMvc;
    @MockBean OrderService orderService;   // Boot 3.4+ 는 @MockitoBean

    @Test
    void returnsOrderAsJson() throws Exception {
        given(orderService.findById(1L)).willReturn(new OrderResponse(1L, "PAID", 12_000));

        mockMvc.perform(get("/orders/1"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.status").value("PAID"))
            .andExpect(jsonPath("$.totalAmount").value(12000));
    }

    @Test
    void returns404WhenMissing() throws Exception {
        given(orderService.findById(9L)).willThrow(new OrderNotFoundException(9L));

        mockMvc.perform(get("/orders/9")).andExpect(status().isNotFound());
    }
}
```

**반드시 컨트롤러를 지정하라.** `@WebMvcTest` 만 쓰면 모든 컨트롤러가 뜨고,
그 모든 의존성을 목으로 채워야 한다.

여기서 검증할 것: URL 매핑, HTTP 메서드, 상태 코드, **JSON 필드명**,
`@Valid` 검증 응답, 예외→상태 매핑, 헤더.

여기서 검증하지 말 것: 비즈니스 로직 (목이라 검증되지 않는다).

> `jsonPath` 경로는 경계면이다. DTO 필드명을 바꾸면 여기가 조용히 깨진다.
> `tdd-boundary-inspector` 가 대조하는 2순위 항목이다.

Spring Boot 3.4+ 에서 `@MockBean` 은 deprecated 다 → `@MockitoBean` 을 쓴다.

---

## @DataJpaTest

JPA 계층만. 엔티티, 리포지토리, `TestEntityManager`. 기본적으로 **트랜잭션 롤백**되고
기본적으로 **임베디드 DB로 치환**된다.

```java
@DataJpaTest
class OrderRepositoryTest {

    @Autowired OrderRepository repository;
    @Autowired TestEntityManager em;

    @Test
    void findsByStatusOrderedByCreatedAt() {
        em.persist(order("PAID",    Instant.parse("2026-01-02T00:00:00Z")));
        em.persist(order("PAID",    Instant.parse("2026-01-01T00:00:00Z")));
        em.persist(order("PENDING", Instant.parse("2026-01-03T00:00:00Z")));
        em.flush();

        var found = repository.findByStatusOrderByCreatedAtAsc("PAID");

        assertThat(found).hasSize(2)
            .extracting(Order::getCreatedAt)
            .isSorted();
    }
}
```

**H2로 치환하면 무엇을 잃는가:** 방언 차이(Postgres `jsonb`, `ILIKE`, 배열),
락 동작, 실제 인덱스 성능. 그 부분을 검증하려면 실제 DB가 필요하다:

```java
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Testcontainers
class OrderRepositoryIT { ... }
```

`em.flush()` 를 잊지 마라. 영속성 컨텍스트에만 있으면 쿼리가 그걸 못 본다.
`em.clear()` 를 더하면 1차 캐시 없이 진짜 로딩을 검증할 수 있다.

---

## @JsonTest

직렬화만. 가장 빠른 Spring 슬라이스다.

```java
@JsonTest
class OrderResponseJsonTest {

    @Autowired JacksonTester<OrderResponse> json;

    @Test
    void serializesAmountAsNumber() throws Exception {
        assertThat(json.write(new OrderResponse(1L, "PAID", 12_000)))
            .hasJsonPathNumberValue("$.totalAmount")
            .extractingJsonPathStringValue("$.status").isEqualTo("PAID");
    }
}
```

커스텀 `@JsonSerializer`, 날짜 포맷, `@JsonNaming` 전략을 검증할 때 쓴다.

---

## @RestClientTest

외부 HTTP 호출. `MockRestServiceServer` 로 응답을 고정한다.

```java
@RestClientTest(PaymentClient.class)
class PaymentClientTest {

    @Autowired PaymentClient client;
    @Autowired MockRestServiceServer server;

    @Test
    void parsesApprovalResponse() {
        server.expect(requestTo("/payments/1"))
              .andRespond(withSuccess("{\"approved\":true}", MediaType.APPLICATION_JSON));

        assertThat(client.check(1L).approved()).isTrue();
    }
}
```

---

## @DataRedisTest

Redis 접근만. 임베디드 Redis 또는 Testcontainers 가 필요하다.
연결이 없으면 `infra-red` 이지 RED가 아니다.

---

## @SpringBootTest

전체 컨텍스트. **비싸다.**

```java
@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT)
@AutoConfigureMockMvc
class OrderFlowIT { ... }
```

여기서만 검증할 수 있는 것: 빈 배선, `@ConfigurationProperties` 바인딩,
`@Transactional` 전파가 실제 레이어를 가로질러 동작하는지, 이벤트 발행/수신.

`webEnvironment` 선택:

| 값 | 의미 |
|---|---|
| `MOCK` (기본) | 서블릿 컨테이너 없음. `MockMvc` 사용 |
| `RANDOM_PORT` | 실제 포트. `TestRestTemplate` / `WebTestClient` |
| `DEFINED_PORT` | 고정 포트 — CI 에서 충돌한다. 쓰지 마라 |
| `NONE` | 웹 환경 없음 |

**사이클당 한 개.** 두 개 이상 필요하다고 느끼면 슬라이스 선택이 틀렸다.

---

## 컨텍스트 캐시

Spring Test 는 컨텍스트를 캐시하고 **설정이 같은 테스트끼리 재사용**한다.
느림의 원인은 컨텍스트를 띄우는 것 자체가 아니라 **캐시 미스**다.

캐시 키를 바꾸는 것들:

| 요인 | 영향 |
|---|---|
| `@MockBean` / `@MockitoBean` 조합 | 조합마다 새 컨텍스트 |
| `@TestPropertySource`, `@ActiveProfiles` | 값마다 새 컨텍스트 |
| `@SpringBootTest(properties = ...)` | 값마다 새 컨텍스트 |
| `@Import`, `@ContextConfiguration` | 조합마다 새 컨텍스트 |
| **`@DirtiesContext`** | 캐시를 **파괴**한다. 최악 |

진단:

```sh
./gradlew :app:test --tests '*IT' --debug 2>&1 | grep -c 'Starting.*Application'
```

이 숫자가 테스트 클래스 수에 가까우면 캐시가 전혀 안 듣고 있는 것이다.

대책: ① 슬라이스를 좁혀 목 자체를 없앤다 ② 목 조합을 공통 기반 클래스나
`@TestConfiguration` 으로 표준화한다 ③ `@DirtiesContext` 를 지운다
(정말 필요하면 그 테스트를 마지막 클래스로 몰아라).

---

## 안티패턴

### `@SpringBootTest` 를 기본값으로 쓰기

가장 비싼 대가를 치르는 흔한 습관. "어차피 나중에 필요할 테니" 는 이유가 아니다.

### `@Transactional` 을 테스트에 붙여 정리 대체

`@DataJpaTest` 는 이미 트랜잭션 롤백한다. 직접 붙이면 프로덕션의 트랜잭션 경계를
테스트가 가려 버려서, **실제로는 커밋 후 lazy 로딩이 터지는 코드가 초록으로 통과**한다.
이건 경계면 결함을 숨기는 전형적 패턴이다.

### `@MockBean` 으로 컨텍스트 실패 덮기

`@WebMvcTest` 가 없는 협력자 때문에 실패하는 것은 정당한 RED다.
`@MockBean` 으로 덮으면 명세가 사라진다.

### 슬라이스 안에서 비즈니스 로직 검증

`@WebMvcTest` 에서 계산 결과를 단언하는데 그 계산이 목에서 온다면,
검증하는 것은 자기가 적어 준 값뿐이다.

### `@DirtiesContext` 를 습관적으로

거의 언제나 잘못된 정리 방식의 증상이다. 상태를 남기는 테스트를 고쳐라.

### 랜덤·현재 시각에 의존

`Instant.now()`, `Random`, `UUID.randomUUID()` 를 검증 대상에 쓰면
간헐 실패가 생기고, 간헐 실패는 RED 신호를 못 믿게 만든다.
`Clock` 을 주입하고 테스트에서 `Clock.fixed(...)` 를 넣어라.
