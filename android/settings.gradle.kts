rootProject.name = "whiplash-android"

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

// shared/ は Xcode からも単独でビルドする Gradle のルートなので、取り込まずに composite build でつなぐ。
// shared のルートプロジェクトには group が無いため、座標を決めて差し替える。
includeBuild("../shared") {
    dependencySubstitution {
        substitute(module("com.yamitzky.whiplash:shared")).using(project(":"))
    }
}

include(":app")
