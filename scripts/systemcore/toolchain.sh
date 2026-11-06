# shellcheck shell=bash
# Sourced: WPILib's SystemCore cross toolchain (aarch64-systemcore2027-linux-gnu-gcc; its sysroot matches the
# SystemCore image: glibc 2.42, libjpeg-turbo 3, libstdc++ 6.0.33). Git Bash on Windows or Linux.
# Sets SC_CC, SC_CXX, SC_SYSROOT and SC_JNI (a JDK-like dir with include/jni.h + include/linux/jni_md.h).
# Override with WPI=.../wpilib/2027_xxx/systemcore and JDK=<any JDK>.
WPI=${WPI:-$(ls -d /c/Users/Public/wpilib/2027*/systemcore "$HOME"/wpilib/2027*/systemcore 2>/dev/null | tail -1 || true)}
[[ -d $WPI/bin ]] || { echo "no WPILib SystemCore toolchain (set WPI=.../wpilib/2027_xxx/systemcore)" >&2; exit 1; }
_exe=""
[[ -f $WPI/bin/aarch64-systemcore2027-linux-gnu-gcc.exe ]] && _exe=.exe
SC_CC=$WPI/bin/aarch64-systemcore2027-linux-gnu-gcc$_exe
SC_CXX=$WPI/bin/aarch64-systemcore2027-linux-gnu-g++$_exe
SC_SYSROOT=$WPI/aarch64-linux-gnu/sysroot
JDK=${JDK:-$(ls -d /c/Users/Public/wpilib/2027*/jdk "$HOME"/wpilib/2027*/jdk /usr/lib/jvm/java-* 2>/dev/null | tail -1 || true)}
SC_JNI=${SC_JNI:-$HOME/builder/sc-jni}
if [[ ! -f $SC_JNI/include/linux/jni_md.h ]]; then
  mkdir -p "$SC_JNI/include/linux"
  cp "$JDK/include/jni.h" "$SC_JNI/include/"
  # A Windows JDK ships only win32/jni_md.h; this is the Linux one.
  cat >"$SC_JNI/include/linux/jni_md.h" <<'H'
#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_
#define JNIEXPORT __attribute__((visibility("default")))
#define JNIIMPORT __attribute__((visibility("default")))
#define JNICALL
typedef int jint;
typedef long jlong;
typedef signed char jbyte;
#endif
H
fi
export SC_CC SC_CXX SC_SYSROOT SC_JNI
