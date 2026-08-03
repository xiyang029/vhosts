plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import com.android.build.gradle.internal.api.BaseVariantOutputImpl

val releaseKeyProperties = Properties().apply {
    val keyPropertiesFile = rootProject.file("key.properties")
    if (keyPropertiesFile.exists()) {
        keyPropertiesFile.inputStream().use(::load)
    }
}

android {
    namespace = "com.xiyang.vhosts"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.xiyang.vhosts"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 33
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = "vhosts"
    }

    signingConfigs {
        create("release") {
            keyAlias = releaseKeyProperties["keyAlias"] as String?
            keyPassword = releaseKeyProperties["keyPassword"] as String?
            storeFile = (releaseKeyProperties["storeFile"] as String?)?.let { rootProject.file(it) }
            storePassword = releaseKeyProperties["storePassword"] as String?
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            manifestPlaceholders["appLabel"] = "vhosts debug"
        }

        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            manifestPlaceholders["appLabel"] = "vhosts"
        }
    }
}

flutter {
    source = "../.."
}

android.applicationVariants.all {
    if (buildType.name == "debug") {
        outputs.all {
            (this as BaseVariantOutputImpl).outputFileName = "vhosts-${versionName}.apk"
        }
    }
}

tasks.withType<com.flutter.gradle.tasks.FlutterTask>().configureEach {
    doFirst {
        if (name.contains("Release")) {
            dartObfuscation = true
            splitDebugInfo = layout.buildDirectory.dir("flutter-symbols").get().asFile.absolutePath
            extraGenSnapshotOptions = listOfNotNull(extraGenSnapshotOptions, "--strip")
                .joinToString(",")
        }
    }
}
