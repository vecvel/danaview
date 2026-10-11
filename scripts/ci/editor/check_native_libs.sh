#!/usr/bin/env bash
# OWNER: AI-04
#
# Checks the native libraries inside Android AABs/APKs (ai.md §4.3, BUILD_PLAN AI-04). Used by the
# editor CI and, later, INT-05's Android release workflow step.
#
#   bash scripts/ci/editor/check_native_libs.sh [options] <app.aab|app.apk> [more archives...]
#
# For each archive it checks:
#   1. ABIs: the whisper libraries are exactly arm64-v8a/{libvwish_whisper.so, libvwish_whisper_v82.so}
#      and x86_64/libvwish_whisper.so: every ABI in --abis, and any of the two that is present, is
#      complete; nothing in armeabi-v7a, x86 or under another name (D-43(b)).
#   2. 16 KB pages: every LOAD segment of every 64-bit .so (arm64-v8a, x86_64) is aligned to >= 16384
#      (llvm-readelf -l). --align-scope whisper limits this to the whisper libraries.
#   3. Exports: the defined dynamic symbols of each whisper library are exactly the VW_API functions of
#      packages/vwish_whisper/src/vw_whisper.h (all vw_*); no libc++_shared.so dependency (c++_static).
#   4. Size: each whisper library is <= --max-bytes (default 3 MB = 3145728 bytes, as packaged).
#   5. ELF machine matches the ABI folder.
#
# Options:
#   --abis "<abi> ..."        ABIs that must carry whisper (default "arm64-v8a x86_64"; use
#                             "arm64-v8a" or "x86_64" for a per-ABI split APK)
#   --align-scope all|whisper which .so files the 16 KB check covers (default all)
#   --max-bytes N             size limit per whisper .so (default 3145728)
#
# Tools: llvm-readelf from the Android NDK (toolchains/llvm/prebuilt/<host>/bin; host folder from
# uname -s: darwin-x86_64, linux-x86_64 or windows-x86_64 with .exe). NDK lookup: VWISH_LLVM_READELF,
# ANDROID_NDK_HOME, ANDROID_NDK_ROOT, ANDROID_NDK, then <sdk>/ndk/28.2.13676358, then the newest
# <sdk>/ndk/*; the SDK is ANDROID_HOME, ANDROID_SDK_ROOT or the platform default.
# Unpacking uses the JDK's `jar` (JAVA_HOME/bin or PATH): every machine that builds an AAB/APK has a
# JDK (Gradle needs one), on macOS, Linux and Windows (Git Bash has no zip and may lack unzip). `unzip`
# is the fallback when no JDK is found.
# Never logs anything but library names, ABIs, sizes, alignments and symbol names.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HEADER="$REPO_ROOT/packages/vwish_whisper/src/vw_whisper.h"
PINNED_NDK="28.2.13676358"

ABIS="arm64-v8a x86_64"
ALIGN_SCOPE="all"
MAX_BYTES=3145728
ARCHIVES=()

in_gha() { [ "${GITHUB_ACTIONS:-}" = "true" ]; }
err() {
  if in_gha; then echo "::error::check_native_libs: $*"; else echo "ERROR: $*" >&2; fi
}
note() {
  if in_gha; then echo "::notice::check_native_libs: $*"; else echo "note: $*"; fi
}
group_start() { if in_gha; then echo "::group::$*"; else echo "== $*"; fi; }
group_end() { if in_gha; then echo "::endgroup::"; fi; }
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --abis) ABIS="${2:?--abis needs a value}"; shift 2 ;;
    --abis=*) ABIS="${1#--abis=}"; shift ;;
    --align-scope) ALIGN_SCOPE="${2:?--align-scope needs a value}"; shift 2 ;;
    --align-scope=*) ALIGN_SCOPE="${1#--align-scope=}"; shift ;;
    --max-bytes) MAX_BYTES="${2:?--max-bytes needs a value}"; shift 2 ;;
    --max-bytes=*) MAX_BYTES="${1#--max-bytes=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do ARCHIVES+=("$1"); shift; done ;;
    -*) err "unknown option $1"; usage >&2; exit 2 ;;
    *) ARCHIVES+=("$1"); shift ;;
  esac
done

case "$ALIGN_SCOPE" in all|whisper) ;; *) err "--align-scope must be all or whisper"; exit 2 ;; esac
case "$MAX_BYTES" in ''|*[!0-9]*) err "--max-bytes must be a number of bytes"; exit 2 ;; esac
for abi in $ABIS; do
  case "$abi" in arm64-v8a|x86_64) ;; *) err "--abis: whisper ships arm64-v8a and x86_64 only (got $abi)"; exit 2 ;; esac
done
if [ "${#ARCHIVES[@]}" -eq 0 ]; then
  err "no AAB/APK given"
  usage >&2
  exit 2
fi

# ---------------------------------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------------------------------
EXE=""
case "$(uname -s)" in
  Darwin*) NDK_HOST="darwin-x86_64" ;;
  Linux*) NDK_HOST="linux-x86_64" ;;
  MINGW*|MSYS*|CYGWIN*) NDK_HOST="windows-x86_64"; EXE=".exe" ;;
  *) err "unsupported host $(uname -s)"; exit 1 ;;
esac

readelf_in() { # <ndk dir> -> prints the llvm-readelf path if present
  local candidate="$1/toolchains/llvm/prebuilt/$NDK_HOST/bin/llvm-readelf$EXE"
  if [ -f "$candidate" ]; then echo "$candidate"; fi
}

find_readelf() {
  local found="" ndk sdk dir newest
  if [ -n "${VWISH_LLVM_READELF:-}" ] && [ -f "$VWISH_LLVM_READELF" ]; then echo "$VWISH_LLVM_READELF"; return; fi
  for ndk in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK:-}"; do
    [ -n "$ndk" ] || continue
    found="$(readelf_in "$ndk")"
    if [ -n "$found" ]; then echo "$found"; return; fi
  done
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" \
             "${LOCALAPPDATA:-}/Android/Sdk"; do
    [ -n "$sdk" ] && [ -d "$sdk" ] || continue
    found="$(readelf_in "$sdk/ndk/$PINNED_NDK")"
    if [ -n "$found" ]; then echo "$found"; return; fi
    newest=""
    if [ -d "$sdk/ndk" ]; then
      for dir in "$sdk"/ndk/*; do
        [ -d "$dir" ] && [ -n "$(readelf_in "$dir")" ] && newest="$dir"
      done
    fi
    if [ -z "$newest" ] && [ -d "$sdk/ndk-bundle" ]; then newest="$sdk/ndk-bundle"; fi
    if [ -n "$newest" ]; then
      found="$(readelf_in "$newest")"
      if [ -n "$found" ]; then echo "$found"; return; fi
    fi
  done
}

READELF="$(find_readelf)"
if [ -z "$READELF" ]; then
  err "llvm-readelf not found. Install the Android NDK $PINNED_NDK (sdkmanager \"ndk;$PINNED_NDK\") and set ANDROID_HOME or ANDROID_NDK_HOME."
  exit 1
fi

UNPACK=""
if [ -n "${JAVA_HOME:-}" ] && [ -f "$JAVA_HOME/bin/jar$EXE" ]; then
  UNPACK="$JAVA_HOME/bin/jar$EXE"
elif command -v jar >/dev/null 2>&1 && jar --version >/dev/null 2>&1; then
  UNPACK="$(command -v jar)"
elif command -v unzip >/dev/null 2>&1; then
  UNPACK="unzip"
else
  err "no unpack tool: install a JDK 17 (it provides jar) and set JAVA_HOME, or install unzip."
  exit 1
fi

list_entries() { # <archive> -> entry names, one per line
  if [ "$UNPACK" = "unzip" ]; then unzip -Z1 "$1"; else "$UNPACK" tf "$1"; fi
}
extract_entries() { # <archive> <dest dir> <entry>...
  local archive="$1" dest="$2"
  shift 2
  if [ "$UNPACK" = "unzip" ]; then
    unzip -q -o "$archive" "$@" -d "$dest"
  else
    (cd "$dest" && "$UNPACK" xf "$archive" "$@")
  fi
}

# Expected exports: the VW_API function names of vw_whisper.h (C ABI). Falls back to "vw_* only".
EXPECTED_EXPORTS=""
if [ -f "$HEADER" ]; then
  EXPECTED_EXPORTS="$(tr -d '\r' < "$HEADER" \
    | sed -n 's/^VW_API[^(]*[^A-Za-z0-9_]\(vw_[A-Za-z0-9_]*\)[[:space:]]*(.*/\1/p' | LC_ALL=C sort -u)"
fi
if [ -z "$EXPECTED_EXPORTS" ]; then
  note "vw_whisper.h not found or empty: checking that every export starts with vw_ only"
fi

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t vwish_native)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

abs_path() { # <file> -> absolute path
  local d
  d="$(cd "$(dirname "$1")" && pwd)"
  echo "$d/$(basename "$1")"
}

FAILURES=0
fail() { err "$*"; FAILURES=$((FAILURES + 1)); }

load_aligns() { # <so> -> one alignment value (hex) per LOAD segment
  "$READELF" -lW "$1" | tr -d '\r' | awk '$1 == "LOAD" { print $NF }'
}
elf_machine() { # <so> -> Machine field
  "$READELF" -hW "$1" | tr -d '\r' | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p'
}
defined_exports() { # <so> -> sorted defined GLOBAL/WEAK dynamic symbol names
  "$READELF" --dyn-syms -W "$1" | tr -d '\r' \
    | awk '$1 ~ /^[0-9]+:$/ && $7 != "UND" && ($5 == "GLOBAL" || $5 == "WEAK") && NF >= 8 { print $8 }' \
    | sed 's/@.*//' | LC_ALL=C sort -u
}
needed_libs() { # <so>
  "$READELF" -dW "$1" | tr -d '\r' | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'
}
file_bytes() { wc -c < "$1" | tr -d ' \r'; }

check_alignment() { # <so> <label>
  local so="$1" label="$2" align bad="" count=0 value
  for align in $(load_aligns "$so"); do
    count=$((count + 1))
    value=$((align))
    if [ "$value" -lt 16384 ] || [ $((value % 16384)) -ne 0 ]; then bad="$bad $align"; fi
  done
  if [ "$count" -eq 0 ]; then
    fail "$label: no LOAD segments (not an ELF shared object?)"
  elif [ -n "$bad" ]; then
    fail "$label: LOAD segments not 16 KB aligned:$bad"
  else
    echo "  ok   16 KB LOAD alignment ($count segments): $label"
  fi
}

check_archive() {
  local archive="$1" abs entries so_entries whisper_entries entry abi name dest so size \
        expected_set actual_set exports bad_exports missing extra machine want_machine needed
  if [ ! -f "$archive" ]; then fail "archive not found: $archive"; return; fi
  abs="$(abs_path "$archive")"
  group_start "check_native_libs: $(basename "$archive")"

  entries="$(list_entries "$abs" | tr -d '\r')" || { fail "cannot list $(basename "$archive")"; group_end; return; }
  # AAB: base/lib/<abi>/<lib>.so (or <module>/lib/...); APK: lib/<abi>/<lib>.so
  so_entries="$(printf '%s\n' "$entries" | grep -E '^([^/]+/)?lib/[^/]+/[^/]+\.so$' || true)"
  if [ -z "$so_entries" ]; then
    fail "$(basename "$archive"): no native libraries found"
    group_end
    return
  fi
  echo "  native libraries:"
  printf '%s\n' "$so_entries" | sed 's/^/    /'

  whisper_entries="$(printf '%s\n' "$so_entries" | grep -E '/lib/[^/]+/libvwish_whisper[^/]*\.so$|^lib/[^/]+/libvwish_whisper[^/]*\.so$' || true)"

  # 1. ABIs and file names of the whisper libraries. Every ABI named by --abis must be complete; an
  #    ABI outside --abis may also be present (AGP builds the plugin's own abiFilters even for a
  #    single-ABI app build) but then complete too. Anything else (armeabi-v7a, x86, another name) fails.
  actual_set="$(printf '%s\n' "$whisper_entries" | sed '/^$/d' | sed -E 's#^([^/]+/)?lib/##' | LC_ALL=C sort -u)"
  local present_abis required_abis
  present_abis="$(printf '%s\n' "$actual_set" | sed '/^$/d' | sed 's#/.*##' | grep -E '^(arm64-v8a|x86_64)$' || true)"
  required_abis="$(printf '%s\n' $ABIS $present_abis | sed '/^$/d' | LC_ALL=C sort -u)"
  expected_set=""
  for abi in $required_abis; do
    case "$abi" in
      arm64-v8a) expected_set="$expected_set
arm64-v8a/libvwish_whisper.so
arm64-v8a/libvwish_whisper_v82.so" ;;
      x86_64) expected_set="$expected_set
x86_64/libvwish_whisper.so" ;;
    esac
  done
  expected_set="$(printf '%s\n' "$expected_set" | sed '/^$/d' | LC_ALL=C sort -u)"
  missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$expected_set") <(printf '%s\n' "$actual_set") | sed '/^$/d')"
  extra="$(LC_ALL=C comm -13 <(printf '%s\n' "$expected_set") <(printf '%s\n' "$actual_set") | sed '/^$/d')"
  if [ -n "$missing" ]; then fail "missing whisper libraries: $(echo $missing)"; fi
  if [ -n "$extra" ]; then fail "unexpected whisper libraries (only arm64-v8a and x86_64, D-43(b)): $(echo $extra)"; fi
  if [ -z "$missing" ] && [ -z "$extra" ]; then
    echo "  ok   whisper libraries are exactly: $(echo $expected_set)"
  fi

  # Extract what we inspect: every 64-bit .so (alignment) or only the whisper ones.
  dest="$TMP_ROOT/$(basename "$archive").d"
  mkdir -p "$dest"
  local to_extract
  if [ "$ALIGN_SCOPE" = "all" ]; then
    to_extract="$(printf '%s\n' "$so_entries" | grep -E '/(arm64-v8a|x86_64)/' || true)"
  else
    to_extract="$whisper_entries"
  fi
  to_extract="$(printf '%s\n%s\n' "$to_extract" "$whisper_entries" | sed '/^$/d' | LC_ALL=C sort -u)"
  if [ -n "$to_extract" ]; then
    # shellcheck disable=SC2046 # entry names never contain spaces (lib/<abi>/<name>.so)
    extract_entries "$abs" "$dest" $(printf '%s\n' "$to_extract") || { fail "cannot extract libraries"; group_end; return; }
  fi

  # 2. 16 KB alignment (64-bit ABIs only; 32-bit devices use 4 KB pages).
  local to_align
  to_align="$(printf '%s\n' "$to_extract" | grep -E '/(arm64-v8a|x86_64)/' || true)"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    so="$dest/$entry"
    if [ ! -f "$so" ]; then fail "$entry: not extracted"; continue; fi
    check_alignment "$so" "$entry"
  done <<EOF_ALIGN
$to_align
EOF_ALIGN

  # 3-5. Exports, STL, size and machine of each whisper library.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    so="$dest/$entry"
    [ -f "$so" ] || continue
    abi="$(echo "$entry" | sed -E 's#^([^/]+/)?lib/([^/]+)/.*#\2#')"
    name="$(basename "$entry")"

    exports="$(defined_exports "$so")"
    bad_exports="$(printf '%s\n' "$exports" | sed '/^$/d' | grep -v '^vw_' || true)"
    if [ -n "$bad_exports" ]; then
      fail "$abi/$name exports non-vw_ symbols: $(echo $bad_exports | cut -c1-400)"
    elif [ -n "$EXPECTED_EXPORTS" ] && [ "$exports" != "$EXPECTED_EXPORTS" ]; then
      fail "$abi/$name exports differ from vw_whisper.h: missing [$(LC_ALL=C comm -23 <(printf '%s\n' "$EXPECTED_EXPORTS") <(printf '%s\n' "$exports") | tr '\n' ' ')] extra [$(LC_ALL=C comm -13 <(printf '%s\n' "$EXPECTED_EXPORTS") <(printf '%s\n' "$exports") | tr '\n' ' ')]"
    elif [ -z "$exports" ]; then
      fail "$abi/$name exports nothing"
    else
      echo "  ok   exports: $abi/$name exports exactly $(printf '%s\n' "$exports" | sed '/^$/d' | wc -l | tr -d ' ') vw_* symbols"
    fi

    needed="$(needed_libs "$so")"
    if printf '%s\n' "$needed" | grep -q 'libc++_shared\.so'; then
      fail "$abi/$name depends on libc++_shared.so (must link c++_static)"
    else
      echo "  ok   STL: $abi/$name has no libc++_shared.so dependency (needs: $(echo $needed))"
    fi

    size="$(file_bytes "$so")"
    if [ "$size" -gt "$MAX_BYTES" ]; then
      fail "$abi/$name is $size bytes (> $MAX_BYTES)"
    else
      echo "  ok   size: $abi/$name $size bytes (<= $MAX_BYTES)"
    fi

    machine="$(elf_machine "$so")"
    case "$abi" in
      arm64-v8a) want_machine="AArch64" ;;
      x86_64) want_machine="Advanced Micro Devices X86-64" ;;
      *) want_machine="" ;;
    esac
    if [ -n "$want_machine" ] && [ "$machine" != "$want_machine" ]; then
      fail "$abi/$name has ELF machine '$machine' (want '$want_machine')"
    fi
  done <<EOF_WHISPER
$whisper_entries
EOF_WHISPER

  group_end
}

echo "check_native_libs: llvm-readelf: $(basename "$READELF") ($NDK_HOST), unpack: $(basename "$UNPACK"), ABIs: $ABIS, align scope: $ALIGN_SCOPE"
for archive in "${ARCHIVES[@]}"; do
  check_archive "$archive"
done

if [ "$FAILURES" -gt 0 ]; then
  err "$FAILURES check(s) failed"
  exit 1
fi
echo "check_native_libs: all checks passed (${#ARCHIVES[@]} archive(s))"
