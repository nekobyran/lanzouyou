import org.gradle.api.GradleException
import org.gradle.api.tasks.Exec
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.Sync

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "cc.nkbr.lanzouyou"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cc.nkbr.lanzouyou"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_secure_storage 10.x requires API 23 or newer.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    sourceSets.getByName("main").jniLibs.srcDir(
        layout.buildDirectory.dir("generated/rustJniLibs").get().asFile,
    )

    // Transitive plugins can publish dartjni helpers for legacy ABIs even
    // though this application only contains Flutter AOT and Rust cores for
    // arm64-v8a and x86_64. Exclude unusable helper-only ABI slices.
    packaging {
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/libdartjni.so",
                "lib/x86/libdartjni.so",
            )
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

val rustCrateDir = rootProject.projectDir.resolve("../native/lanzouyou_core")
val rustLibraryName = "liblanzouyou_core.so"
val rustTargets = linkedMapOf(
    "arm64-v8a" to "aarch64-linux-android",
    "x86_64" to "x86_64-linux-android",
)
val rustInputs = fileTree(rustCrateDir) {
    include("Cargo.toml", "Cargo.lock", "build.rs", "src/**/*.rs")
}
val ndkDirectory = android.sdkDirectory.resolve("ndk/${android.ndkVersion}")
val hostTag = when {
    System.getProperty("os.name").startsWith("Windows", ignoreCase = true) -> "windows-x86_64"
    System.getProperty("os.name").startsWith("Mac", ignoreCase = true) -> "darwin-x86_64"
    else -> "linux-x86_64"
}
val executableSuffix = if (hostTag.startsWith("windows")) ".exe" else ""
val clangSuffix = if (hostTag.startsWith("windows")) ".cmd" else ""
val llvmBin = ndkDirectory.resolve("toolchains/llvm/prebuilt/$hostTag/bin")
val llvmAr = llvmBin.resolve("llvm-ar$executableSuffix")
val cargoCommand = providers.environmentVariable("CARGO").orElse("cargo").get()
val generatedRustJniDir = layout.buildDirectory.dir("generated/rustJniLibs")

fun registerRustBuildTask(
    taskName: String,
    rustTarget: String,
    release: Boolean,
) = tasks.register<Exec>(taskName) {
    val profile = if (release) "release" else "debug"
    val output = rustCrateDir.resolve("target/$rustTarget/$profile/$rustLibraryName")
    val linker = llvmBin.resolve("${rustTarget}24-clang$clangSuffix")
    val environmentTarget = rustTarget.uppercase().replace('-', '_')

    workingDir = rustCrateDir
    inputs.files(rustInputs).withPathSensitivity(PathSensitivity.RELATIVE)
    outputs.file(output)
    doFirst {
        if (!rustCrateDir.resolve("Cargo.toml").isFile) {
            throw GradleException("Rust crate not found: $rustCrateDir")
        }
        if (!linker.isFile || !llvmAr.isFile) {
            throw GradleException(
                "Android NDK toolchain is incomplete for $rustTarget: $llvmBin",
            )
        }
    }
    environment("ANDROID_NDK_HOME", ndkDirectory.absolutePath)
    environment("CARGO_TARGET_${environmentTarget}_LINKER", linker.absolutePath)
    environment("CC_${rustTarget.replace('-', '_')}", linker.absolutePath)
    environment("CC_$rustTarget", linker.absolutePath)
    environment("AR_${rustTarget.replace('-', '_')}", llvmAr.absolutePath)
    environment("AR_$rustTarget", llvmAr.absolutePath)
    val arguments = mutableListOf("build", "--locked", "--target", rustTarget)
    if (release) {
        arguments.add(1, "--release")
    }
    commandLine(listOf(cargoCommand) + arguments)
}

val debugRustTasks = rustTargets.map { (abi, rustTarget) ->
    registerRustBuildTask(
        "buildDebugRustLanzouCore${abi.replace("-", "_").replaceFirstChar(Char::uppercase)}",
        rustTarget,
        false,
    )
}
val releaseRustTasks = rustTargets.map { (abi, rustTarget) ->
    registerRustBuildTask(
        "buildReleaseRustLanzouCore${abi.replace("-", "_").replaceFirstChar(Char::uppercase)}",
        rustTarget,
        true,
    )
}

val syncDebugRustJniLibs by tasks.registering(Sync::class) {
    dependsOn(debugRustTasks)
    into(generatedRustJniDir)
    rustTargets.forEach { (abi, rustTarget) ->
        from(rustCrateDir.resolve("target/$rustTarget/debug/$rustLibraryName")) {
            into(abi)
        }
    }
}

val syncReleaseRustJniLibs by tasks.registering(Sync::class) {
    dependsOn(releaseRustTasks)
    into(generatedRustJniDir)
    rustTargets.forEach { (abi, rustTarget) ->
        from(rustCrateDir.resolve("target/$rustTarget/release/$rustLibraryName")) {
            into(abi)
        }
    }
}

tasks.matching { it.name == "preDebugBuild" }.configureEach {
    dependsOn(syncDebugRustJniLibs)
}
tasks.matching { it.name in setOf("preProfileBuild", "preReleaseBuild") }.configureEach {
    dependsOn(syncReleaseRustJniLibs)
}
