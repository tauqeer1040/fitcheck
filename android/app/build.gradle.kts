plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.FileInputStream
import java.util.Properties

android {
    namespace = "com.taucity.stickerpants"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Release signing from android/key.properties (gitignored, never
    // committed). Without it, release falls back to debug keys for local
    // `flutter run --release` only — store uploads always use release.
    val keystoreProps = Properties()
    val keystorePropsFile = rootProject.file("key.properties")
    if (keystorePropsFile.exists()) {
        keystoreProps.load(FileInputStream(keystorePropsFile))
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications: java.time & friends on
        // API < 26 run through the desugar ladder.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.taucity.stickerpants"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (keystorePropsFile.exists()) {
                signingConfigs {
                    create("release") {
                        storeFile = file(keystoreProps["storeFile"] as String)
                        storePassword = keystoreProps["storePassword"] as String
                        keyAlias = keystoreProps["keyAlias"] as String
                        keyPassword = keystoreProps["keyPassword"] as String
                    }
                }
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Local dev only: debug keys so `flutter run --release` works.
                signingConfig = signingConfigs.getByName("debug")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
