import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名：优先本地 key.properties（开发者机器），
// 其次 CI 注入的环境变量（GitHub Actions，keystore 由 secret 解出），
// 都没有才回退 debug 签名。
// 注意：同一应用所有发布包必须同一签名，否则覆盖安装会失败。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val ciKeystoreFile = File(System.getenv("KEYSTORE_FILE") ?: "")
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null || ciKeystoreFile.exists()

android {
    namespace = "com.example.dlg_q"
    compileSdk = 35
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                if (keystoreProperties.getProperty("storeFile") != null) {
                    storeFile = file(keystoreProperties.getProperty("storeFile")!!)
                    storePassword = keystoreProperties.getProperty("storePassword")
                    keyAlias = keystoreProperties.getProperty("keyAlias")
                    keyPassword = keystoreProperties.getProperty("keyPassword")
                } else {
                    storeFile = ciKeystoreFile
                    storePassword = System.getenv("KEYSTORE_PASSWORD")
                    keyAlias = System.getenv("KEY_ALIAS")
                    keyPassword = System.getenv("KEY_PASSWORD")
                }
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.dlg_q"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 有发布密钥用发布签名，否则退回 debug（仅限本地临时构建）
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 禁用 R8 代码混淆，避免 release 模式下第三方库被混淆导致渲染异常
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}
