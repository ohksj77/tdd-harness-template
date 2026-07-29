# E2E 픽스처

훅이 **실제 Gradle 출력**에 반응하는지 증명하기 위한 최소 단일 모듈 프로젝트다.
Layer 1 이 canned 데이터로 검증하는 것을 여기서는 진짜로 돌려 확인한다.

- `:core` — 순수 Java. JUnit 5 + AssertJ + Mockito.

의도적으로 없는 것:

- **Gradle wrapper** — `tests/e2e/tdd-cycle.sh` 는 시스템 `gradle` 을 쓴다.
  훅의 명령 매처는 `gradlew` 와 `gradle` 을 모두 인식하며, 이 테스트의 관심사는
  래퍼 프로비저닝이 아니라 훅↔Gradle 연동이다.
- **툴체인 고정** — 고정하면 개발 머신의 JDK 버전에 따라 테스트가 깨진다.
- **Spring 모듈** — Spring 버전을 고정하면 유지보수 부담만 늘고, `:core` 가
  증명하지 못하는 것을 증명하지 못한다. 분류기 입장에서 `@WebMvcTest` 결과 XML 은
  다른 JUnit XML 과 완전히 같다. 유일하게 흥미로운 케이스인 "컨텍스트 로드 실패"는
  `tests/hooks/golden/spring-context-error.xml` 로 결정적으로 검증한다.
- **Kotlin 모듈** — kotlinc 컴파일 실패 경로는
  `tests/hooks/golden/compile-red-kotlinc.log` 로 검증한다.

`src/**` 아래 소스는 E2E 실행 중에 생성·삭제된다. 비어 있는 것이 정상이다.
