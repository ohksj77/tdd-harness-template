---
name: spring-test-slice-selection
description: "Spring Boot 테스트에서 가장 좁은 슬라이스를 고르는 결정 표. @WebMvcTest, @DataJpaTest, @SpringBootTest, @RestClientTest, @JsonTest, @DataRedisTest 중 무엇을 쓸지, 언제 슬라이스 없이 순수 단위 테스트로 갈지, @MockBean 이 컨텍스트 캐시를 어떻게 망가뜨리는지, Testcontainers 를 언제 붙일지에 사용. 컨트롤러 테스트, 리포지토리 테스트, 서비스 테스트 작성 시 반드시 참조. 테스트가 느리다, 컨텍스트가 안 뜬다, 슬라이스를 바꿔달라 같은 후속 요청에도 사용."
---

# Spring 테스트 슬라이스 선택

**틀린 이유로 실패하지 않는 가장 좁은 테스트를 고른다.**

이건 스타일 취향이 아니라 TDD가 살아남느냐의 문제다. 잘못 고른
`@SpringBootTest` 하나가 0.3초 RED를 25초로 만들고, 25초짜리 루프는 지켜지지 않는다.
사람도 에이전트도 결국 테스트를 건너뛰기 시작한다.

## 결정 표 — 위에서부터 읽고 처음 맞는 것을 쓴다

| 무엇을 검증하는가 | 선택 | 대략 비용 |
|---|---|---|
| 순수 로직: 계산, 분기, 검증 규칙, 도메인 불변식 | **슬라이스 없음** (POJO + Mockito) | ~10ms |
| 서비스 로직 (협력자는 더블) | **슬라이스 없음** (`@ExtendWith(MockitoExtension.class)`) | ~10ms |
| HTTP 매핑, 상태 코드, 직렬화, 검증 애노테이션 | `@WebMvcTest(XxxController.class)` | ~1-3s |
| JPA 매핑, 쿼리 메서드, `@Query`, 제약 조건 | `@DataJpaTest` | ~2-4s |
| JSON 직렬화/역직렬화만 | `@JsonTest` | ~0.5s |
| 외부 HTTP 클라이언트 | `@RestClientTest` | ~1s |
| Redis 접근 | `@DataRedisTest` | ~2s + 컨테이너 |
| 여러 레이어를 가로지르는 실제 흐름 | `@SpringBootTest` | ~10-30s |

**기본값은 "슬라이스 없음"이다.** Spring 컨텍스트가 필요한 이유를 한 문장으로
말할 수 없으면 필요 없는 것이다.

## 판단 기준: 이 테스트가 무엇 때문에 실패해야 하는가

| 실패해야 하는 이유 | 필요한 것 |
|---|---|
| 내 계산이 틀렸다 | 아무것도 (new 로 만든다) |
| 내가 협력자를 잘못 호출했다 | Mockito |
| 내 URL/상태코드/JSON 필드명이 틀렸다 | `@WebMvcTest` |
| 내 쿼리나 엔티티 매핑이 틀렸다 | `@DataJpaTest` |
| 배선이 틀렸다 (빈이 안 뜬다) | `@SpringBootTest` |

배선 검증은 **사이클당 한 번**이면 족하다. 모든 테스트에서 반복할 이유가 없다.

## 흔한 오답

### `@SpringBootTest` 로 서비스 로직 테스트

```java
@SpringBootTest                       // ✗ 25초
class OrderServiceTest {
    @Autowired OrderService service;
    @MockBean PaymentGateway gateway;
}
```

```java
@ExtendWith(MockitoExtension.class)   // ✓ 10ms, 같은 것을 검증한다
class OrderServiceTest {
    @Mock PaymentGateway gateway;
    @InjectMocks OrderService service;
}
```

서비스가 스스로 컨텍스트를 요구하지 않는다면 — 그리고 대부분은 요구하지 않는다 —
Spring은 이 테스트에 아무것도 보태지 않는다.

### `@WebMvcTest` 없이 컨트롤러를 new 로 호출

```java
var response = controller.getOrder(1L);   // ✗ 매핑·검증·직렬화를 전혀 검증하지 못한다
```

컨트롤러의 계약은 자바 메서드 시그니처가 아니라 **HTTP 표면**이다.
`@WebMvcTest` + `MockMvc` 로 URL·상태 코드·JSON 경로를 검증해야 의미가 있다.

### `@MockBean` 남용

`@MockBean` 은 컨텍스트 캐시 키를 바꾼다. 조합이 다를 때마다 새 컨텍스트가 뜬다.
`@MockBean` 조합이 서로 다른 테스트 클래스 20개면 컨텍스트 20개다.

대책: 슬라이스를 좁히거나(그러면 목이 애초에 필요 없다), 목 조합을 공통
`@TestConfiguration` 으로 표준화한다.

## TDD 사이클에서의 실전 순서

한 기능을 만들 때 슬라이스가 섞이는 것이 정상이다:

```
1. 도메인 규칙       → 슬라이스 없음      (RED → GREEN, 수 초)
2. 서비스 조합       → 슬라이스 없음 + 목  (RED → GREEN, 수 초)
3. HTTP 표면        → @WebMvcTest        (RED → GREEN, 수 초)
4. 영속성 매핑       → @DataJpaTest       (RED → GREEN, 수 초)
5. 배선 확인         → @SpringBootTest 1개 (사이클 마감에 한 번)
```

1~4가 사이클의 몸통이고 5는 마감이다. 5로 시작하면 사이클이 성립하지 않는다.

## 컨텍스트가 안 뜨는 것도 RED 다

`@WebMvcTest(OrderController.class)` 가 아직 없는 `OrderService` 때문에 실패하면,
결과 XML에 `errors="1"` 로 잡히고 메시지는 이렇다:

```
NoSuchBeanDefinitionException: No qualifying bean of type 'com.acme.OrderService'
```

이건 **정당한 RED** 다 — "그 협력자를 만들어라"는 명세다.
상태 머신도 이걸 RED로 세고, 메시지 안의 FQCN을 스코프 신호로 쓴다.
다만 `@MockBean OrderService` 로 급히 덮으면 그 명세가 사라진다.

## 더 읽기

- 슬라이스별 상세와 안티패턴: [references/slice-catalog.md](references/slice-catalog.md)
- Testcontainers 를 언제 어떻게 붙이는가: [references/testcontainers.md](references/testcontainers.md)
