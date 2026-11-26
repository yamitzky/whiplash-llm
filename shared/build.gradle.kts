import java.util.Base64

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.kmp.library)
}

val embedSwiftFixtures: TaskProvider<EmbedSwiftFixtures> = tasks.register<EmbedSwiftFixtures>("embedSwiftFixtures") {
    fixtureDir.set(layout.projectDirectory.dir("src/commonTest/fixtures/swift"))
    outputDir.set(layout.buildDirectory.dir("generated/swiftFixtures/kotlin"))
}

kotlin {
    jvmToolchain(21)

    android {
        namespace = "com.yamitzky.whiplash.shared"
        compileSdk = libs.versions.android.compileSdk.get().toInt()
        minSdk = libs.versions.android.minSdk.get().toInt()
        withHostTest {}
    }

    macosArm64()
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "WhiplashShared"
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(libs.kotlinx.coroutines.core)
            implementation(libs.kotlinx.serialization.json)
            implementation(libs.ktor.client.core)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.kotlinx.coroutines.test)
            implementation(libs.ktor.client.mock)
        }
        androidMain.dependencies {
            implementation(libs.ktor.client.okhttp)
        }
        appleMain.dependencies {
            implementation(libs.ktor.client.darwin)
        }
        commonTest {
            kotlin.srcDir(embedSwiftFixtures.map { it.outputDir })
        }
    }
}

/**
 * Swift が書き出した fixture (src/commonTest/fixtures/swift) を Kotlin のソースに埋め込む。
 * commonTest には JVM と Kotlin/Native の両方で使えるファイル読み込みが無く、
 * テストの作業ディレクトリもターゲットごとに違うため、実行時に読まずにビルド時に埋め込む。
 */
abstract class EmbedSwiftFixtures : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val fixtureDir: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun embed() {
        val root = fixtureDir.get().asFile
        val entries = root.walkTopDown()
            .filter { it.isFile && !it.name.startsWith(".") }
            .map { it.relativeTo(root).invariantSeparatorsPath to Base64.getEncoder().encodeToString(it.readBytes()) }
            .sortedBy { it.first }
            .joinToString("\n") { (path, data) -> "    \"$path\" to \"$data\"," }
        val out = outputDir.get().asFile.resolve("com/yamitzky/whiplash/shared/SwiftFixtureFiles.kt")
        out.parentFile.mkdirs()
        out.writeText(
            """
            |// shared/build.gradle.kts の embedSwiftFixtures が生成する。手で書き換えない。
            |package com.yamitzky.whiplash.shared
            |
            |/** fixture のパス (シナリオ/before か after/ファイル名) と、Swift が書いたバイト列の Base64。 */
            |internal val swiftFixtureFiles: Map<String, String> = mapOf(
            |$entries
            |)
            |""".trimMargin()
        )
    }
}
