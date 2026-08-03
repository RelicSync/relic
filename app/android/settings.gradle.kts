pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Pinned to AGP 8.9.1 / Gradle 8.12 (see gradle-wrapper.properties) / Kotlin
    // 2.1.20 on purpose. super_clipboard's native build (irondash 0.5.5 cargokit)
    // calls Gradle's Project.exec(), which Gradle 9 removed — AGP 9 forces Gradle
    // 9, so the whole APK build fails on it. Stay on the AGP 8.x / Gradle 8.x line
    // until super_clipboard ships a Gradle-9-compatible cargokit. (Bumped 8.7.3 →
    // 8.9.1 because floating transitive androidx deps — core 1.17.0, browser 1.9.0
    // — now require AGP 8.9.1+; 8.9.1 still runs on Gradle 8.12, so it's safe.)
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.20" apply false
}

include(":app")
