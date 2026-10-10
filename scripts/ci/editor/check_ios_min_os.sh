#!/usr/bin/env bash
# OWNER: ENG-09
#
# D-41 guard: fails when an iOS binary could not load or would crash on the iOS 15.0 floor
# (ARCH §3.1, D-29). It checks every Mach-O image and static archive member in the given paths:
#
#   1. minimum OS: LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS (`xcrun vtool -show-build`, or
#      `otool -l` for archive members) must be <= the floor for every iOS / iOS-simulator slice;
#   2. linked libraries (`otool -L` / `otool -l`): no strongly linked framework or Swift runtime
#      dylib introduced after the floor (NEWER_LIBRARIES below); a framework introduced after the
#      floor may only be weak-linked when it is on the allowlist (WEAK_ALLOWLIST: adopting one
#      is reviewed, not accidental). Weak links to frameworks that exist on the floor are fine
#      (ld weak-links a framework by itself when every reference to it is guarded) and are only
#      listed;
#   3. strongly bound symbols (`nm -um`): every non-weak undefined C/Objective-C symbol imported
#      from a system framework or libSystem is looked up in the SDK headers by compiling a probe
#      at `-target arm64-apple-ios<floor>` with -Werror=unguarded-availability(-new); a symbol
#      the compiler reports as "only available on iOS N or newer" fails the check. (Weak
#      references, i.e. code behind `#available` / `__builtin_available`, are fine.) Swift and
#      C++ mangled symbols are not probed: the Swift and Clang compilers weak-link anything newer
#      than the target, so those are covered by check 1 plus -Werror=unguarded-availability-new
#      in the pods (ENG-07, AI-05).
#
# Usage:
#   scripts/ci/editor/check_ios_min_os.sh [--min 15.0] [--allow-weak NAME]... PATH...
#   scripts/ci/editor/check_ios_min_os.sh --self-test
#
# PATH may be an .app, a .framework, an .xcframework (its ios-* slices), a static library, a
# Mach-O file or any directory (searched recursively; .dSYM bundles are skipped). The script is
# run by ios.sh on the example host's Runner.app, the engine pod framework and
# WhisperCore.xcframework, and by INT-05's iOS release lane on the app.
#
# --self-test builds negative fixtures (a strongly bound iOS 17 symbol at minimum OS 15.0, a
# binary, an archive member and an embedded framework built for iOS 17, a strongly linked iOS 16
# framework, a weak-linked iOS 16 framework outside the allowlist) and positive ones (the same
# iOS 17 symbol behind __builtin_available, weak links to BackgroundTasks and to an allowlisted
# iOS 16 framework, a clean archive) and checks that the script fails and passes on exactly those.
#
# Environment: VWISH_IOS_MIN_OS (default 15.0), VWISH_MIN_OS_WEAK_ALLOW (extra allowlist names).
# Output names binaries relative to the given path; it never prints media or user content.
set -euo pipefail

SCRIPT="${BASH_SOURCE[0]}"
MIN_OS="${VWISH_IOS_MIN_OS:-15.0}"

# Frameworks introduced after the floor that may be weak-linked. A weak link is only safe when
# every use is guarded, so a new entry needs a review of the code that uses it. BackgroundTasks
# exists on iOS 15 but its iOS 26 continued-processing API is what the export service guards
# (IOS-13), so it is listed for the record.
WEAK_ALLOWLIST="BackgroundTasks ${VWISH_MIN_OS_WEAK_ALLOW:-}"

# System frameworks and Swift runtime dylibs introduced after iOS 15.0 ("name first-iOS-version").
# Strongly linking one of these makes dyld abort the launch on older iOS. Extend this list when the
# app adopts a newer framework (and weak-link it, adding it to WEAK_ALLOWLIST).
NEWER_LIBRARIES="
ProximityReader 15.4
AppIntents 16.0
AVRouting 16.0
Charts 16.0
CoreTransferable 16.0
ExtensionKit 16.0
MetalFX 16.0
RoomPlan 16.0
SafetyKit 16.0
SharedWithYou 16.0
SharedWithYouCore 16.0
Spatial 16.0
WeatherKit 16.0
ActivityKit 16.1
BackgroundAssets 16.1
MatterSupport 16.1
Cinematic 17.0
DeveloperToolsSupport 17.0
SensitiveContentAnalysis 17.0
SwiftData 17.0
Symbols 17.0
TipKit 17.0
WorkoutKit 17.0
JournalingSuggestions 17.2
AdAttributionKit 17.4
BrowserEngineCore 17.4
BrowserEngineKit 17.4
FinanceKit 17.4
FinanceKitUI 17.4
LiveCommunicationKit 17.4
MarketplaceKit 17.4
Translation 17.4
AccessorySetupKit 18.0
ContactProvider 18.0
LockedCameraCapture 18.0
SwiftUICore 18.0
TranslationUIProvider 18.0
ImagePlayground 18.1
AlarmKit 26.0
DeclaredAgeRange 26.0
FoundationModels 26.0
libswift_StringProcessing 16.0
libswift_RegexBuilder 16.0
libswiftDistributed 16.0
libswiftObservation 17.0
libswiftSynchronization 18.0
"

GHA="${GITHUB_ACTIONS:-}"
note() { if [ "$GHA" = true ]; then echo "::notice title=check_ios_min_os::$1"; else echo "note: $1"; fi; }
fail_msg() { if [ "$GHA" = true ]; then echo "::error title=check_ios_min_os (D-41)::$1"; else echo "FAIL: $1" >&2; fi; }

usage() { sed -n '2,38p' "$SCRIPT" | sed 's/^# \{0,1\}//'; }

# vgt A B: true when version A > version B (numeric, up to three components).
vgt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, A, "."); nb = split(b, B, ".");
    for (i = 1; i <= 3; i++) { x = (i <= na) ? A[i] + 0 : 0; y = (i <= nb) ? B[i] + 0 : 0;
      if (x > y) exit 0; if (x < y) exit 1 }
    exit 1 }'
}

# ---------------------------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------------------------
self_test() {
  local dir sdk status=0
  dir="$(mktemp -d "${TMPDIR:-/tmp}/vwish_min_os_selftest.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" EXIT
  sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
  cc() { xcrun --sdk iphoneos clang -isysroot "$sdk" "$@"; }

  # CMTaggedBufferGroupGetCount is API_AVAILABLE(ios(17.0)) in CoreMedia. Declaring it by hand
  # without availability makes clang bind it strongly, exactly the bug this guard exists for.
  printf '%s\n' '#include <stddef.h>' \
    'extern long CMTaggedBufferGroupGetCount(const void *group);' \
    'int main(void) { return (int)CMTaggedBufferGroupGetCount(NULL); }' >"$dir/strong17.c"
  cc -target "arm64-apple-ios$MIN_OS" "$dir/strong17.c" -framework CoreMedia -o "$dir/neg_strong_ios17_symbol"

  # The same symbol through the SDK header behind __builtin_available: weak, so it passes.
  printf '%s\n' '#include <CoreMedia/CoreMedia.h>' \
    'int main(void) {' \
    '  if (__builtin_available(iOS 17.0, *)) { return (int)CMTaggedBufferGroupGetCount(NULL); }' \
    '  return 0;' \
    '}' >"$dir/weak17.c"
  cc -target "arm64-apple-ios$MIN_OS" -Wno-nonnull "$dir/weak17.c" -framework CoreMedia -o "$dir/pos_weak_ios17_symbol"

  printf '%s\n' '#include <stdio.h>' 'int main(void) { puts("x"); return 0; }' >"$dir/plain.c"
  # Built for iOS 17: the minimum OS check fails.
  cc -target arm64-apple-ios17.0 "$dir/plain.c" -o "$dir/neg_minos_17"
  # An archive whose second member was built for iOS 17.
  printf '%s\n' 'int vwish_a(void) { return 1; }' >"$dir/a.c"
  printf '%s\n' 'int vwish_b(void) { return 2; }' >"$dir/b.c"
  cc -target "arm64-apple-ios$MIN_OS" -c "$dir/a.c" -o "$dir/a.o"
  cc -target arm64-apple-ios17.0 -c "$dir/b.c" -o "$dir/b.o"
  xcrun --sdk iphoneos libtool -static -o "$dir/neg_archive_member_17.a" "$dir/a.o" "$dir/b.o" 2>/dev/null
  # A clean archive.
  xcrun --sdk iphoneos libtool -static -o "$dir/pos_archive.a" "$dir/a.o" 2>/dev/null
  # Strongly linked iOS 16 framework (ld keeps the load command without -dead_strip_dylibs).
  cc -target "arm64-apple-ios$MIN_OS" "$dir/plain.c" -framework AppIntents -o "$dir/neg_strong_framework_16"
  # Weak links: BackgroundTasks (on the floor) is fine; AppIntents (iOS 16) only when allowlisted.
  cc -target "arm64-apple-ios$MIN_OS" "$dir/plain.c" -weak_framework BackgroundTasks -o "$dir/pos_weak_floor_framework"
  cc -target "arm64-apple-ios$MIN_OS" "$dir/plain.c" -weak_framework AppIntents -o "$dir/neg_weak_newer_not_allowlisted"
  cp "$dir/neg_weak_newer_not_allowlisted" "$dir/pos_weak_newer_allowlisted"
  # A minimal .app bundle around the clean binary, with an embedded framework built for iOS 17.
  mkdir -p "$dir/Neg.app/Frameworks/Late.framework"
  cp "$dir/pos_weak_ios17_symbol" "$dir/Neg.app/Neg"
  cc -target arm64-apple-ios17.0 -dynamiclib "$dir/a.c" -install_name @rpath/Late.framework/Late \
    -o "$dir/Neg.app/Frameworks/Late.framework/Late"

  local name expect got allow
  for name in neg_strong_ios17_symbol pos_weak_ios17_symbol neg_minos_17 neg_archive_member_17.a \
    pos_archive.a neg_strong_framework_16 pos_weak_floor_framework neg_weak_newer_not_allowlisted \
    pos_weak_newer_allowlisted Neg.app; do
    case "$name" in pos_*) expect=0 ;; *) expect=1 ;; esac
    allow=""
    [ "$name" = pos_weak_newer_allowlisted ] && allow=AppIntents
    got=0
    VWISH_MIN_OS_WEAK_ALLOW="$allow" bash "$SCRIPT" --min "$MIN_OS" "$dir/$name" >"$dir/out.txt" 2>&1 || got=$?
    if { [ "$expect" -eq 0 ] && [ "$got" -eq 0 ]; } || { [ "$expect" -ne 0 ] && [ "$got" -eq 1 ]; }; then
      echo "self-test ok: $name (exit $got)"
    else
      fail_msg "self-test: $name exited $got, expected $([ "$expect" -eq 0 ] && echo 0 || echo 1)"
      sed 's/^/    /' "$dir/out.txt" >&2
      status=1
    fi
  done
  # The strong-symbol fixture must fail for the symbol itself, not for anything else.
  VWISH_MIN_OS_WEAK_ALLOW="" bash "$SCRIPT" --min "$MIN_OS" "$dir/neg_strong_ios17_symbol" >"$dir/out.txt" 2>&1 || true
  if ! grep -q 'CMTaggedBufferGroupGetCount.*iOS 17.0' "$dir/out.txt"; then
    fail_msg "self-test: the strong iOS 17 symbol was not named in the report"
    sed 's/^/    /' "$dir/out.txt" >&2
    status=1
  fi
  if [ "$status" -eq 0 ]; then echo "check_ios_min_os.sh self-test passed"; fi
  return "$status"
}

# ---------------------------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------------------------
declare -a TARGETS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --min) MIN_OS="$2"; shift 2 ;;
    --allow-weak) WEAK_ALLOWLIST="$WEAK_ALLOWLIST $2"; shift 2 ;;
    --self-test) self_test; exit $? ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done
if [ "${#TARGETS[@]}" -eq 0 ]; then
  usage >&2
  exit 2
fi

for tool in vtool otool nm lipo clang; do
  if ! xcrun --find "$tool" >/dev/null 2>&1; then
    fail_msg "xcrun cannot find $tool: install Xcode (and run xcodebuild -runFirstLaunch)"
    exit 2
  fi
done
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vwish_min_os.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILURES="$WORK/failures.txt"
SYMBOLS="$WORK/symbols.tsv"
: >"$FAILURES"
: >"$SYMBOLS"
IMAGES=0

record_failure() { echo "$1" >>"$FAILURES"; fail_msg "$1"; }

# Lists the Mach-O files and archives under a target (one per line).
list_binaries() {
  local target="$1"
  if [ -f "$target" ]; then
    echo "$target"
    return
  fi
  local root="$target"
  if [ "${target%.xcframework}" != "$target" ] || [ "${target%.xcframework/}" != "$target" ]; then
    # Only the iOS slices (ios-arm64, ios-arm64_x86_64-simulator); never macOS or Catalyst.
    find "$target" -maxdepth 1 -type d -name 'ios-*' ! -name '*maccatalyst*' | while IFS= read -r slice; do
      find "$slice" -type d -name '*.dSYM' -prune -o -type f -print
    done
    return
  fi
  find "$root" -type d -name '*.dSYM' -prune -o -type d -name '_CodeSignature' -prune -o -type f -print
}

is_binary() {
  case "$(file -b "$1" 2>/dev/null)" in
    *Mach-O* | *"ar archive"*) return 0 ;;
    *) return 1 ;;
  esac
}

is_archive() { case "$(file -b "$1" 2>/dev/null)" in *"ar archive"*) return 0 ;; *) return 1 ;; esac; }

# Prints "<member>\t<platform>\t<minos>" for every build-version load command.
build_versions() {
  local file="$1" arch="$2"
  local out
  if is_archive "$file"; then
    out="$(xcrun otool -arch "$arch" -l "$file" 2>/dev/null || true)"
  else
    out="$(xcrun vtool -arch "$arch" -show-build "$file" 2>/dev/null || xcrun otool -arch "$arch" -l "$file" 2>/dev/null || true)"
  fi
  printf '%s\n' "$out" | awk '
    # Archive members print as "lib.a(member.o):"; image headers ("x (architecture arm64):") are not members.
    /^[^ \t].*\([^()]+\.o\):$/ { member = $0; sub(/\):$/, "", member); sub(/^.*\(/, "", member) }
    # (An empty member prints as "-": bash read collapses empty tab-separated fields.)
    $1 == "cmd" { cmd = $2; if (member == "") member = "-"; next }
    cmd == "LC_BUILD_VERSION" && $1 == "platform" { plat = $2; next }
    cmd == "LC_BUILD_VERSION" && $1 == "minos" { print member "\t" plat "\t" $2; next }
    cmd ~ /^LC_VERSION_MIN_IPHONEOS$/ && $1 == "version" { print member "\tIOS\t" $2; next }
    cmd ~ /^LC_VERSION_MIN_(MACOSX|TVOS|WATCHOS)$/ && $1 == "version" { print member "\tOTHER\t" $2; next }
  '
}

# Prints "STRONG|WEAK\t<install name>" for every linked library.
linked_libraries() {
  local file="$1" arch="$2"
  xcrun otool -arch "$arch" -l "$file" 2>/dev/null | awk '
    $1 == "cmd" { cmd = $2; next }
    $1 == "name" && (cmd == "LC_LOAD_DYLIB" || cmd == "LC_REEXPORT_DYLIB" || cmd == "LC_LOAD_UPWARD_DYLIB") { print "STRONG\t" $2; next }
    $1 == "name" && cmd == "LC_LOAD_WEAK_DYLIB" { print "WEAK\t" $2; next }
  '
}

library_name() {
  local path="$1" base
  base="${path##*/}"
  case "$path" in
    */Frameworks/*.framework/*) base="${path%.framework/*}"; base="${base##*/}" ;;
    *.dylib) base="${base%.dylib}"; base="${base%%.*}" ;;
  esac
  echo "$base"
}

newer_version_of() {
  printf '%s\n' "$NEWER_LIBRARIES" | awk -v n="$1" '$1 == n { print $2; exit }'
}

in_weak_allowlist() {
  local n
  for n in $WEAK_ALLOWLIST; do [ "$n" = "$1" ] && return 0; done
  return 1
}

check_binary() {
  local file="$1" label="$2" arch archs platform_seen=false
  archs="$(xcrun lipo -archs "$file" 2>/dev/null || true)"
  if [ -z "$archs" ]; then
    note "$label: no architectures (skipped)"
    return
  fi
  IMAGES=$((IMAGES + 1))
  for arch in $archs; do
    # 1. Minimum OS.
    local member platform minos
    while IFS="$(printf '\t')" read -r member platform minos; do
      [ -z "$platform" ] && continue
      [ "$member" = "-" ] && member=""
      case "$platform" in
        2 | 7 | IOS | IOSSIMULATOR)
          platform_seen=true
          if vgt "$minos" "$MIN_OS"; then
            record_failure "$label${member:+ ($member)} [$arch]: minimum iOS $minos is above $MIN_OS"
          fi
          ;;
        *)
          record_failure "$label${member:+ ($member)} [$arch]: built for platform $platform, not iOS"
          ;;
      esac
    done < <(build_versions "$file" "$arch")

    # 2. Linked libraries (images only; archives link nothing).
    if ! is_archive "$file"; then
      local kind path name since
      while IFS="$(printf '\t')" read -r kind path; do
        [ -z "$path" ] && continue
        name="$(library_name "$path")"
        since="$(newer_version_of "$name")"
        case "$path" in
          /System/Library/Frameworks/* | /usr/lib/swift/*)
            if [ "$kind" = STRONG ] && [ -n "$since" ] && vgt "$since" "$MIN_OS"; then
              record_failure "$label [$arch]: strongly links $name (iOS $since); weak-link it and guard every use"
            fi
            if [ "$kind" = WEAK ] && [ -n "$since" ] && vgt "$since" "$MIN_OS" && ! in_weak_allowlist "$name"; then
              record_failure "$label [$arch]: weak-links $name (iOS $since), which is not on the allowlist (review its guards, then add it to WEAK_ALLOWLIST)"
            fi
            if [ "$kind" = WEAK ]; then echo "$name" >>"$WORK/weak.txt"; fi
            ;;
        esac
      done < <(linked_libraries "$file" "$arch")
    fi

    # 3. Strongly bound undefined symbols, grouped by the library they come from.
    xcrun nm -arch "$arch" -um "$file" 2>/dev/null | awk -v label="$label" '
      /\(undefined\)/ && !/weak external/ {
        sym = ""; from = "unknown";
        for (i = 1; i <= NF; i++) if ($i == "external") { sym = $(i + 1); break }
        if (match($0, /\(from [^)]*\)/)) { from = substr($0, RSTART + 6, RLENGTH - 7) }
        if (sym != "") print from "\t" sym "\t" label
      }' >>"$SYMBOLS" || true
  done
  if [ "$platform_seen" != true ] && ! is_archive "$file"; then
    note "$label: no iOS build version load command"
  fi
}

# ---------------------------------------------------------------------------------------------
# Availability probe (check 3)
# ---------------------------------------------------------------------------------------------
LIBC_HEADERS="stdlib.h stdio.h string.h math.h time.h unistd.h pthread.h sys/mman.h sys/stat.h
dispatch/dispatch.h os/lock.h os/log.h os/signpost.h os/proc.h malloc/malloc.h mach/mach.h
mach/mach_time.h objc/runtime.h objc/message.h zlib.h sqlite3.h os/os_sync_wait_on_address.h
compression.h"
UNKNOWN_FRAMEWORKS="Foundation Accelerate Metal CoreML AVFoundation CoreMedia CoreVideo CoreGraphics UIKit"

probe_headers_for() {
  local lib="$1" h fw
  case "$lib" in
    lib* | unknown | "dynamically looked up")
      for h in $LIBC_HEADERS; do
        [ -f "$SDK/usr/include/$h" ] && echo "#include <$h>"
      done
      if [ "$lib" = unknown ]; then
        for fw in $UNKNOWN_FRAMEWORKS; do echo "#import <$fw/$fw.h>"; done
      fi
      ;;
    *)
      if [ -f "$SDK/System/Library/Frameworks/$lib.framework/Headers/$lib.h" ]; then
        echo "#import <$lib/$lib.h>"
      fi
      ;;
  esac
}

PROBED=0
UNDECLARED=0
probe_symbols() {
  [ -s "$SYMBOLS" ] || return 0
  sort -u -t "$(printf '\t')" -k1,1 -k2,2 "$SYMBOLS" >"$WORK/sorted.tsv"
  local libs lib
  libs="$(cut -f1 "$WORK/sorted.tsv" | sort -u)"
  while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    local headers probe="$WORK/probe.m"
    headers="$(probe_headers_for "$lib")"
    [ -z "$headers" ] && continue
    {
      printf '%s\n' "$headers"
      echo "static void vwish_probe(void) {"
      awk -F '\t' -v lib="$lib" '$1 == lib { print $2 }' "$WORK/sorted.tsv" | sort -u | awk '
        /^_OBJC_(META)?CLASS_\$_[A-Za-z_][A-Za-z0-9_]*$/ { n = $0; sub(/^_OBJC_(META)?CLASS_\$_/, "", n); if (!seen["c" n]++) print "  (void)[" n " class];"; next }
        /^_[A-Za-z][A-Za-z0-9_]*$/ { n = substr($0, 2); if (!seen["s" n]++) print "  (void)&" n ";"; next }
      '
      echo "}"
    } >"$probe"
    local count
    count="$(grep -c '^  (void)' "$probe" || true)"
    [ "${count:-0}" -eq 0 ] && continue
    PROBED=$((PROBED + count))
    local errors
    errors="$(xcrun --sdk iphoneos clang -isysroot "$SDK" -target "arm64-apple-ios$MIN_OS" -fmodules \
      -fsyntax-only -ferror-limit=0 -Wno-deprecated-declarations -Wno-unused-function \
      -Werror=unguarded-availability -Werror=unguarded-availability-new -x objective-c "$probe" 2>&1 || true)"
    UNDECLARED=$((UNDECLARED + $(printf '%s\n' "$errors" | grep -c "undeclared identifier" || true)))
    printf '%s\n' "$errors" | sed -n "s/.*error: '\([A-Za-z0-9_]*\)' is only available on iOS \([0-9.]*\) or newer.*/\1 \2/p" | sort -u |
      while read -r sym since; do
        local where
        where="$(awk -F '\t' -v lib="$lib" -v s1="_$sym" -v s2="_OBJC_CLASS_\$_$sym" -v s3="_OBJC_METACLASS_\$_$sym" \
          '$1 == lib && ($2 == s1 || $2 == s2 || $2 == s3) { print $3; exit }' "$WORK/sorted.tsv")"
        echo "${where:-?}: strongly binds $sym from $lib (iOS $since); guard it with #available so it is weak-linked"
      done >>"$WORK/symbol_failures.txt"
  done <<<"$libs"
  if [ -s "$WORK/symbol_failures.txt" ]; then
    while IFS= read -r line; do record_failure "$line"; done <"$WORK/symbol_failures.txt"
  fi
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
for target in "${TARGETS[@]}"; do
  if [ ! -e "$target" ]; then
    record_failure "$target does not exist"
    continue
  fi
  parent="$(dirname "$target")"
  found=false
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    is_binary "$file" || continue
    found=true
    label="${file#"$parent"/}"
    check_binary "$file" "$label"
  done < <(list_binaries "$target")
  if [ "$found" != true ]; then
    record_failure "$(basename "$target"): no Mach-O binary found"
  fi
done
probe_symbols

echo "check_ios_min_os: floor iOS $MIN_OS, $IMAGES binaries, $PROBED strongly bound C/Objective-C symbols probed ($UNDECLARED not declared in the probe headers, not checked); weak allowlist: $(echo $WEAK_ALLOWLIST)"
if [ -s "$WORK/weak.txt" ]; then echo "check_ios_min_os: weak-linked: $(sort -u "$WORK/weak.txt" | tr '\n' ' ')"; fi
if [ -s "$FAILURES" ]; then
  echo "check_ios_min_os: $(wc -l <"$FAILURES" | tr -d ' ') problem(s) found" >&2
  exit 1
fi
echo "check_ios_min_os: OK"
