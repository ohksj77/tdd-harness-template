// E2E 픽스처. 실제 프로젝트가 아니라, 훅이 진짜 Gradle 출력에 반응하는지
// 증명하기 위한 최소 구성이다.
//
// 툴체인을 고정하지 않는다 — 고정하면 개발 머신의 JDK 버전에 따라 테스트가
// 깨진다. 여기서 검증하려는 건 훅이지 툴체인이 아니다.
// Kotlin 컴파일 실패 경로는 Layer 1 의 kotlinc golden 로그로 검증한다.

allprojects {
    repositories { mavenCentral() }
}

subprojects {
    apply(plugin = "java")

    dependencies {
        "testImplementation"(platform("org.junit:junit-bom:5.11.3"))
        "testImplementation"("org.junit.jupiter:junit-jupiter")
        "testImplementation"("org.assertj:assertj-core:3.26.3")
        "testImplementation"("org.mockito:mockito-core:5.14.2")
        "testImplementation"("org.mockito:mockito-junit-jupiter:5.14.2")
        "testRuntimeOnly"("org.junit.platform:junit-platform-launcher")
    }

    tasks.withType<Test>().configureEach {
        useJUnitPlatform()
        testLogging { events("passed", "failed", "skipped") }
    }
}
