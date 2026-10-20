plugins { id("com.android.application") }
android {
    namespace = "com.xploree.decoder.testhost"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.xploree.decoder.testhost"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    sourceSets["androidTest"].assets.srcDir("../../tools/evaluation/fixtures/shared-engine")
}
dependencies {
    implementation(project(":decoder"))
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
