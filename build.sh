#!/bin/bash
# Horihori build helper for this VM. Working recipe found on 2026-11-20:
# - Flutter 3.47.8 template = Gradle 9.3.1 / AGP 9.1.0. Gradle 9 always runs
#   in a daemon, and the daemon JVM does NOT inherit -D flags from
#   org.gradle.jvmargs, so it used IPv6 loopback and every request to the
#   local mirror was intercepted/reset. JAVA_TOOL_OPTIONS is picked up by
#   every JVM (client + daemon) and fixes it. This is the key setting.
# - Dependencies go through the local curl-backed mirror (tools/mirror.py,
#   port 18080) via .local/gradle-home/init.d/mirror.gradle, and Flutter
#   engine artifacts through .local/flutterio_mirror.py (port 18081).
# - Gradle 9.3.1 distribution is pre-seeded under .local/gradle-home/wrapper
#   (downloaded with curl; Java cannot download it directly).
set -e
cd "$(dirname "$0")"
export JAVA_HOME=~/workspace/tools/jdk21
export ANDROID_HOME=~/workspace/tools/android-sdk
export GRADLE_USER_HOME=~/workspace/idea-stock/.local/gradle-home
export HORIHORI_LOCAL_MIRROR=1
export JAVA_TOOL_OPTIONS="-Djava.net.preferIPv4Stack=true"
export GRADLE_OPTS="-Xmx1024m -Dfile.encoding=UTF-8 -Djava.net.preferIPv4Stack=true"
# v0.1.1: use the project-local Flutter SDK copy (.local/flutter-sdk).
# The shared SDK's flutter_tools included-build lock
# (packages/flutter_tools/gradle/.gradle/buildOutputCleanup) is held by
# other projects' Gradle daemons on this VM and release builds timed out
# waiting for it. android/local.properties flutter.sdk points at the copy.
export PATH=~/workspace/idea-stock/.local/flutter-sdk/bin:$JAVA_HOME/bin:$PATH
# start mirrors if not listening
if ! curl -s -o /dev/null --max-time 3 http://127.0.0.1:18080/central/org/jetbrains/kotlin/kotlin-stdlib/2.4.0/kotlin-stdlib-2.4.0.pom; then
  (cd ~/workspace/tools && nohup python3 mirror.py > /tmp/mirror.log 2>&1 &)
  sleep 1
fi
if ! curl -s -o /dev/null --max-time 3 http://127.0.0.1:18081/flutterio/; then
  (cd .local && nohup python3 flutterio_mirror.py > /tmp/flutterio-mirror.log 2>&1 &)
  sleep 1
fi
# v0.3.0: sync version from pubspec.yaml into android/local.properties.
# Gradle-direct builds do not regenerate it, and a stale file silently
# ships the old versionName/versionCode (happened on the first v0.3.0 build).
VER=$(grep -E '^version:' pubspec.yaml | sed -E 's/version: *([0-9.]+)\+([0-9]+).*/\1 \2/')
VNAME=$(echo $VER | cut -d' ' -f1); VCODE=$(echo $VER | cut -d' ' -f2)
sed -i -E "s/^flutter.versionName=.*/flutter.versionName=$VNAME/; s/^flutter.versionCode=.*/flutter.versionCode=$VCODE/" android/local.properties
G="$GRADLE_USER_HOME/wrapper/dists/gradle-9.3.1-all/9ot9r568e8zfvvd4mn8rbu1j0/gradle-9.3.1/bin/gradle"
# Build serialization rule (user decision 2026-11-23, revised): at most 2
# builds VM-wide, via the shared semaphore wrapper.
cd android && exec ~/workspace/tools/with-build-lock.sh "$G" assembleRelease --max-workers=1 "$@"
