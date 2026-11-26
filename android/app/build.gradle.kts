import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// リリース署名の鍵は android/keystore.properties (gitignore 済み) から読む。
// 無ければ release は署名されないまま作られる。鍵の作り方は android/README.md。
val keystoreProperties = rootProject.file("keystore.properties").takeIf { it.exists() }?.let { file ->
    Properties().apply { file.inputStream().use(::load) }
}

kotlin {
    jvmToolchain(21)
}

android {
    namespace = "com.yamitzky.whiplash.android"
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "com.yamitzky.whiplash.android"
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = 1
        versionName = "0.1.0"
    }

    signingConfigs {
        if (keystoreProperties != null) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
            // OCR のネイティブライブラリが CPU の種類ごとに 11 MB ある。実機の Pixel を含む今の端末は arm64 なので、それだけ入れる。
            // デバッグはエミュレーター (x86_64) でも動くよう、絞らない。
            ndk { abiFilters += "arm64-v8a" }
        }
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(libs.whiplash.shared)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.compose.material.icons)
    implementation(libs.markdown.renderer.m3)
    implementation(libs.mlkit.genai.prompt)
    implementation(libs.mlkit.text.recognition.ja)
    debugImplementation(libs.compose.ui.tooling)
    testImplementation(libs.kotlin.test)
}
