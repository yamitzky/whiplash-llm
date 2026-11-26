plugins {
    alias(libs.plugins.android.application) apply false
    // AGP 9 の組み込み Kotlin が、AGP の既定の版でなく shared と同じ版の Kotlin Gradle プラグインを使うように置く。
    alias(libs.plugins.kotlin.multiplatform) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
