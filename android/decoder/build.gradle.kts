import java.security.MessageDigest

// Include this library in an Android host project with AGP 9+ (built-in Kotlin).
// The host owns plugin versions, SDK/NDK installation and application configuration.
plugins { id("com.android.library") }

android {
    namespace = "com.xploree.decoder"
    compileSdk = 36
    // Select an installed NDK r28+ through the host project; no silent downloads.
    ndkVersion = providers.gradleProperty("xploree.ndkVersion").get().also {
        require((it.substringBefore('.').toIntOrNull() ?: 0) >= 28) { "Use an installed NDK r28+ for 16 KB page-size support" }
    }
    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
        externalNativeBuild { cmake {
            cppFlags += listOf("-std=c++20")
            arguments += listOf("-DANDROID_STL=c++_shared")
        } }
    }
    externalNativeBuild {
        cmake {
            path = file("../../native/android/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/decoder-assets").get().asFile)
}

// Stage the SAME pack and notices; do not commit a second Android dictionary.
val stageDecoderAssets by tasks.registering(Copy::class) {
    from("../../keyboard/langdata.bin", "../../keyboard/safety.kbguard", "../../keyboard/ThirdPartyNotices.txt")
    into(layout.buildDirectory.dir("generated/decoder-assets"))
    doLast {
        val sha = MessageDigest.getInstance("SHA-256")
        file("../../keyboard/langdata.bin").inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                sha.update(buffer, 0, count)
            }
        }
        val hash = sha.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        layout.buildDirectory.file("generated/decoder-assets/langdata.sha256").get().asFile.writeText(hash + "\n")
    }
}
tasks.named("preBuild").configure { dependsOn(stageDecoderAssets) }
