allprojects {
    repositories {
        if (System.getenv("HORIHORI_LOCAL_MIRROR") == "1") {
            maven { url = uri("http://127.0.0.1:18080/google"); isAllowInsecureProtocol = true }
            maven { url = uri("http://127.0.0.1:18080/central"); isAllowInsecureProtocol = true }
        } else {
            google()
            mavenCentral()
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
    // v0.4.0: flutter_secure_storage 等、compileSdk 34 を宣言するプラグインが
    // android-34 の無い環境で落ちるため、ライブラリの compileSdk を 36 へ
    // 引き上げる（ProfileMaker で実績のある方式）。
    if (project.name != "app") {
        afterEvaluate {
            plugins.withId("com.android.library") {
                extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                    val currentSdk = compileSdk ?: 0
                    if (currentSdk < 35) {
                        compileSdk = 36
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
