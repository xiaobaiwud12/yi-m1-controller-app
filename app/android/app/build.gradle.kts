import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing
//
// The release build is signed with the maintainer's own key, read from
// `keystore.properties` next to this file:
//
//     storeFile=keystore/yi-m1-release.jks   # relative to app/android/
//     storePassword=...
//     keyAlias=yi-m1-release
//     keyPassword=...
//
// In the **development repository** both files are tracked on purpose — that
// repository is private forever and already carries the camera's credentials, and
// a self-held signing key whose only copy is one file on one disk is how an app
// becomes permanently un-updatable. In the **release repository** neither file may
// ever appear: `tools/release/export_app_release.ps1` drops them by name and the
// export's scan fails if a keystore-shaped file or a `storePassword=` line
// reappears. `RELEASING.md` in that repository is the procedure.
//
// ## Why this fails loudly instead of falling back to the debug key
//
// Until 2026-09-16 this block was `signingConfig = signingConfigs.getByName("debug")`
// under a `TODO`. The debug keystore is a *publicly known* key — fixed alias, fixed
// password — so anybody could build an APK that Android accepts as a legitimate
// update of this app, and a release that is secretly debug-signed while reporting
// success is exactly the defect class this project spent 2026-09-16 fixing
// (`analysis/63` §4.2 / §9 item 6). A missing key is therefore a **build failure**,
// not a warning, and there is no silent path to a signed artifact.
//
// The one exception is explicit and named: `-PallowDebugSigning=true` produces a
// debug-signed build for local testing, says so in the build log, and is what the
// release repository's README tells a contributor to use. It cannot be reached by
// accident, and it cannot be mistaken for a distributable artifact.
// ---------------------------------------------------------------------------

val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val releaseKeyFields = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val missingKeyFields = releaseKeyFields.filter {
    keystoreProperties.getProperty(it).isNullOrBlank()
}
val hasReleaseKey = keystorePropertiesFile.exists() && missingKeyFields.isEmpty()

// A release *build* is requested by task name, and the check happens at
// configuration time so that a missing key stops the build before anything is
// compiled. Debug and unit-test tasks are untouched by design: contributors and the
// `kotlin` verification layer must keep working without the maintainer's key.
//
// `assemble` and `build` are in the list because they build *every* variant, release
// included — so they need the key just as much as `assembleRelease` does, and they do
// not carry the word in their name.
val releaseTaskRequested = gradle.startParameter.taskNames.any { name ->
    val leaf = name.substringAfterLast(':')
    leaf.contains("Release") || leaf == "assemble" || leaf == "build" || leaf == "bundle"
}
val debugSigningAllowed =
    (project.findProperty("allowDebugSigning") as String?)?.lowercase() == "true"

if (releaseTaskRequested && !hasReleaseKey && !debugSigningAllowed) {
    throw GradleException(
        """
        |Release build refused: no signing key.
        |
        |Looked for : ${keystorePropertiesFile.absolutePath}
        |Missing    : ${
            if (!keystorePropertiesFile.exists()) "the file itself"
            else missingKeyFields.joinToString(", ")
        }
        |
        |A release build must be signed with the maintainer's key. Signing it with the
        |debug key would ship an APK that anybody can impersonate as an update, so this
        |is a failure rather than a fallback.
        |
        |  * to make a distributable build: create the key and this file —
        |    see RELEASING.md in the release repository, or analysis/65 §9 in the
        |    development repository. The keytool invocation is in both.
        |  * to make a throwaway local build: add -PallowDebugSigning=true, which is
        |    debug-signed on purpose and printed as such.
        |  * Flutter passes one through as:
        |    flutter build apk --release --android-project-arg=allowDebugSigning=true
        """.trimMargin()
    )
}

android {
    namespace = "com.cem1.yi_m1_controller"

    // The three SDK levels are written out rather than inherited from
    // `flutter.compileSdkVersion` / `flutter.targetSdkVersion` / `flutter.minSdkVersion`.
    //
    // Not because the inherited values are wrong — measured on this toolchain they are
    // exactly these (36 / 36 / 24; `FlutterExtension.kt` in the Flutter SDK) and 36
    // currently satisfies Play's target-API rule — but because *inheriting* means a
    // Flutter upgrade changes them silently, and `targetSdk` in particular changes
    // runtime behaviour and store eligibility without a single line of this repository
    // changing (`analysis/63` §4.2, §7.3.1). A pinned number is a decision someone can
    // read, diff and argue with.
    compileSdk = 36
    // Left as Flutter's own value on purpose: it names the NDK matching the engine
    // artifacts Flutter ships, and hard-coding a version that is not installed turns a
    // working build into "NDK not configured" on the next Flutter upgrade. The risk
    // that made pinning worth it for `targetSdk` — silent behaviour change — does not
    // apply to the NDK here, because this app has no native code of its own.
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // `com.cem1.yi_m1_controller` is fixed. Android treats the application ID as
        // the app's identity: changing it makes every installed copy a different app,
        // so this is not a renameable string (`analysis/63` §7.3.7).
        applicationId = "com.cem1.yi_m1_controller"
        minSdk = 24
        targetSdk = 36
        // The version code and name come from `app/pubspec.yaml`, which is the single
        // source of truth for what this build is. When using split APKs, 1000 *
        // ABI_VERSION is added automatically by Flutter.
        // (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // `null` here is only reachable when no release task was requested (the
            // configuration-time check above has already thrown otherwise), and this
            // block is evaluated for *every* build — including `assembleDebug`, which
            // is how the first version of this file managed to fail a debug build with
            // "release signing reached without a key".
            signingConfig = when {
                hasReleaseKey -> signingConfigs.getByName("release")
                debugSigningAllowed -> {
                    logger.warn(
                        "WARNING: release build is DEBUG-SIGNED because " +
                            "-PallowDebugSigning=true was given. This artifact is NOT " +
                            "distributable: the debug key is public, so anybody can " +
                            "build an APK Android accepts as an update of this app."
                    )
                    signingConfigs.getByName("debug")
                }
                else -> null
            }
        }
    }

    // Plain JVM unit tests for the small amount of pure logic on the native side
    // (currently `WifiJoinDiagnosis`).  It runs under `gradlew test`, needs no
    // emulator, and exists because the Wi-Fi join diagnosis has been wrong twice
    // in ways only a device could otherwise reveal.
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
