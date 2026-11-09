// Local machine configuration for the Termux SSH Terminal fork.
//
// This file is applied automatically by
// ~/.gradle/init.d/local-env-loader.init.gradle.kts (applied from the root project).
//
// Keep machine-specific / local-build-only settings here instead of editing the
// committed build files. This file IS committed on purpose (see docs/decisions.md),
// so never put secrets, paths or keystore details in it.
//
// Only build the ABI this device actually uses. That keeps the embedded
// bootstrap ZIP count at one and the APK small.
//
// NOTE: this is a Kotlin script applied via `apply(from = ...)` from a Groovy
// init script, so only a minimal Gradle API surface is available here. Any real
// Android DSL work stays in the root `build.gradle`.
gradle.extra.set("useArm64V8aOnly", true)
