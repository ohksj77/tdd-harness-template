# Testcontainers — 언제, 그리고 TDD 루프 밖에서

## 원칙: 사이클 안에 넣지 마라

컨테이너 기동은 초 단위, 때로는 수십 초다. TDD 루프 안에 들어가면 사이클이 죽는다.

```
사이클 안 (초 단위 루프)  → 슬라이스 없음, @WebMvcTest, @DataJpaTest(H2)
사이클 마감 / CI          → Testcontainers
```

Testcontainers 가 답인 경우는 하나다: **H2로는 검증할 수 없는 것을 검증할 때.**

| 검증 대상 | H2 로 되는가 |
|---|---|
| 기본 CRUD, 파생 쿼리 | 된다 |
| `@Query` JPQL | 대체로 된다 |
| 네이티브 SQL, 방언 함수 | **안 된다** |
| Postgres `jsonb`, 배열, `ILIKE` | **안 된다** |
| `SELECT ... FOR UPDATE`, 락 동작 | **안 된다** |
| 인덱스·실행 계획 | **안 된다** |
| Flyway/Liquibase 마이그레이션 실제 적용 | **안 된다** |

마지막 항목이 특히 중요하다. 엔티티↔스키마 경계면 불일치는
마이그레이션을 실제 DB에 적용해 봐야만 드러난다.

## 최소 구성

```java
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Testcontainers
class OrderRepositoryIT {

    @Container
    @ServiceConnection                       // Boot 3.1+ — 수동 프로퍼티 배선 불필요
    static PostgreSQLContainer<?> postgres =
        new PostgreSQLContainer<>("postgres:16-alpine");

    @Autowired OrderRepository repository;

    @Test
    void findsByJsonbAttribute() { ... }
}
```

`static` 이 핵심이다. 인스턴스 필드로 두면 **테스트 메서드마다** 컨테이너가 뜬다.

Boot 3.1 미만이면 `@DynamicPropertySource` 로 직접 배선한다:

```java
@DynamicPropertySource
static void props(DynamicPropertyRegistry registry) {
    registry.add("spring.datasource.url", postgres::getJdbcUrl);
    registry.add("spring.datasource.username", postgres::getUsername);
    registry.add("spring.datasource.password", postgres::getPassword);
}
```

## 컨테이너 재사용

여러 IT 클래스가 같은 컨테이너를 공유하게 하려면 공통 기반 클래스에 `static` 컨테이너를
두고 상속시킨다. JVM 수명 동안 한 번만 뜬다.

```java
public abstract class PostgresSupport {
    @Container @ServiceConnection
    static final PostgreSQLContainer<?> POSTGRES =
        new PostgreSQLContainer<>("postgres:16-alpine");
}
```

`testcontainers.reuse.enable=true` (`~/.testcontainers.properties`) 를 켜면
Gradle 실행 사이에도 재사용된다. 로컬 개발에서는 유용하지만 **CI에서는 켜지 마라** —
테스트 간 격리가 깨진다.

## 별도 소스셋으로 분리하라

```kotlin
// build.gradle.kts
sourceSets {
    create("integrationTest") {
        compileClasspath += sourceSets.main.get().output + configurations.testRuntimeClasspath.get()
        runtimeClasspath += output + compileClasspath
    }
}

val integrationTest by tasks.registering(Test::class) {
    testClassesDirs = sourceSets["integrationTest"].output.classesDirs
    classpath = sourceSets["integrationTest"].runtimeClasspath
    useJUnitPlatform()
    shouldRunAfter(tasks.test)
}
```

이러면 `./gradlew :app:test` 는 빠른 채로 남고, 통합 테스트는 명시적으로만 돈다.

```sh
./gradlew :app:test                 # TDD 루프 — 빠름
./gradlew :app:integrationTest      # 사이클 마감 — 느림
```

## Docker 가 없으면 RED 가 아니다

```
Could not find a valid Docker environment
```

이건 `infra-red` 다. 상태 머신은 전이하지 않고, 테스트를 고쳐서 해결하려 들면 안 된다.
Docker를 켜거나, 그 테스트를 이번 사이클 범위에서 빼라.

CI에서 Docker가 없는 환경이라면 통합 테스트 태스크에 조건을 건다:

```kotlin
integrationTest {
    onlyIf { System.getenv("DOCKER_AVAILABLE") != "false" }
}
```

단, 조용히 건너뛰는 테스트는 없는 테스트와 같다는 점을 잊지 마라 —
건너뛴 사실이 눈에 보이게 하라.
