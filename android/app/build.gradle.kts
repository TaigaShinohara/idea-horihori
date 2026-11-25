import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Dedicated keystore under the project's persistent .local/ (never the
// default debug key: it is regenerated when the VM is replaced).
val signingProps = Properties().apply {
    val f = rootProject.file("../.local/signing.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasDedicatedSigning = signingProps.getProperty("storeFile") != null

android {
    namespace = "com.taigashinohara.horihori"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.taigashinohara.horihori"
        // v0.3.0: flutter_device_ai（ML Kit GenAI）が API 26 を要求するため引き上げ。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // v0.4.2: flutter_device_ai が依存として引き込むローカルLLM実行系
    // （llamadart / LiteRT-LM / llama.cpp / ggml / WebGPU）を APK から除外。
    // 合計で約100MB（非圧縮）あり、120MB APK の主因だった。
    // 根拠: 本アプリのオンデバイス経路は AICore（ML Kit GenAI Prompt API）
    // のみで、生成は AICore のシステムプロセス側で実行されるため、これらの
    // .so は一切ロードされない。ローカルモデル用フォールバック
    // （LocalLlmFallbackAdapter / GGUF）も使っていない
    // （FlutterDeviceAi.withFallback() にアダプタを渡していない）。
    // 万一ローカルLLM経路を使う改修をする場合は、この除外を外すこと。
    packaging {
        jniLibs {
            excludes += listOf(
                "lib/*/libLiteRt*.so",
                "lib/*/libGemmaModelConstraintProvider.so",
                "lib/*/libggml*.so",
                "lib/*/libllama*.so",
                "lib/*/libmtmd.so",
                "lib/*/libwebgpu_dawn.so",
            )
        }
    }

    signingConfigs {
        if (hasDedicatedSigning) {
            create("horihori") {
                storeFile = rootProject.file(signingProps.getProperty("storeFile"))
                storePassword = signingProps.getProperty("storePassword")
                keyAlias = signingProps.getProperty("keyAlias")
                keyPassword = signingProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            if (hasDedicatedSigning) {
                signingConfig = signingConfigs.getByName("horihori")
            }
        }
        release {
            if (hasDedicatedSigning) {
                signingConfig = signingConfigs.getByName("horihori")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
