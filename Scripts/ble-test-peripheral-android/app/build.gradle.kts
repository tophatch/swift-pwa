plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.swiftpwa.blefixture"
    compileSdk = 34

    defaultConfig {
        applicationId = "dev.swiftpwa.blefixture"
        // 31: the fixture asks for BLUETOOTH_ADVERTISE / _CONNECT, which is the
        // modern permission set. Nothing here needs to run on anything older.
        minSdk = 31
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
