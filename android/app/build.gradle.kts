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
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
