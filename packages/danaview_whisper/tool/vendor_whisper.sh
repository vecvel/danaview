#!/usr/bin/env bash
# OWNER: AI-01
#
# Re-vendors whisper.cpp (pruned) into packages/danaview_whisper/third_party/whisper.cpp.
#
#   tool/vendor_whisper.sh                       re-vendor the pinned release (v1.9.4)
#   tool/vendor_whisper.sh --check               rebuild in a temp dir and diff against the committed tree
#   tool/vendor_whisper.sh --tarball FILE        use a local tarball (still sha256 + commit verified)
#   tool/vendor_whisper.sh <tag> <commit>        vendor another release (needs its sha256, see below)
#
# What it does (ai.md §4.2):
#   1. downloads https://github.com/ggml-org/whisper.cpp/archive/refs/tags/<tag>.tar.gz
#   2. verifies the tarball sha256 against the pin below, and that the commit id stored in
#      the archive (git get-tar-commit-id) equals <commit>
#   3. copies ONLY the allowlist below (everything else is pruned: examples, models, bindings,
#      tests, docs, CI, non-shipping backends such as CUDA / Vulkan / OpenCL / SYCL ...)
#   4. writes third_party/.gitignore and the generated block of third_party/VENDORED.md
#
# Only the upstream source tarball is fetched; no models and no other repositories.
# Requirements: bash, curl (unless --tarball), tar, gzip, git (for get-tar-commit-id), sha256sum or shasum.
#
# Pinning another release: pass <tag> <commit> and export DV_WHISPER_SHA256=<tarball sha256>
# (without it the script stops and prints the computed value so you can review it first),
# then update the PIN_* values below, ai.md §4.2 and ARCHITECTURE.md §16.1.
#
# Environment:
#   DV_WHISPER_SHA256   tarball sha256 for a tag/commit that has no pin below
#   DV_VENDOR_DATE      date (YYYY-MM-DD) to record; default: kept if the pin is unchanged, else today (UTC)
#   DV_WHISPER_ALLOW_TARBALL_DRIFT=1
#                       GitHub does not promise byte-stable archives. If only the tarball bytes drifted
#                       (commit id matches), continue and require the extracted tree digest to match
#                       PIN_TREE_SHA256 instead.

set -euo pipefail
export LC_ALL=C

# ---- pin (the release the plan was written against) -------------------------------------------
PIN_TAG="v1.9.4"
PIN_COMMIT="927cfce34f31707e17f2bff35c349632fb9e2c3a"
PIN_TARBALL_SHA256="57e280cee375ab02425b806ad5146b99f6eb9357e3c2b31357c8a6af2e2e44ae"
# sha256 over the sorted "sha256  ./path" lines of the pruned tree (see tree_digest below)
PIN_TREE_SHA256="ef776faa224dece8284ccd09da70ae11d683448e67b0798b575ea8e69ad1037a"

UPSTREAM="https://github.com/ggml-org/whisper.cpp"

# ---- allowlist (everything not listed is pruned) ----------------------------------------------
KEEP_FILES=(
  CMakeLists.txt
  LICENSE
  ggml/CMakeLists.txt
  ggml/src/CMakeLists.txt
  ggml/src/ggml-version.h.in
  samples/jfk.wav                          # public-domain speech, tests only
  bindings/javascript/package-tmpl.json    # top-level CMake configure_file()s it (see VENDORED.md)
)
KEEP_DIRS=(
  cmake
  include
  src                                      # whisper.cpp, parakeet.cpp, coreml/ (later), vitisai/, openvino/
  ggml/cmake
  ggml/include
  ggml/src/ggml-cpu
  ggml/src/ggml-metal
  ggml/src/ggml-blas
)
# plus ggml/src/*.{c,cpp,h} (top level of ggml/src only)

# ---- helpers ----------------------------------------------------------------------------------
die() { echo "vendor_whisper: $*" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then sha256_stdin() { sha256sum | cut -d' ' -f1; }
                                               sha256_files() { xargs -0 sha256sum; }
elif command -v shasum >/dev/null 2>&1; then   sha256_stdin() { shasum -a 256 | cut -d' ' -f1; }
                                               sha256_files() { xargs -0 shasum -a 256; }
else die "need sha256sum or shasum"; fi

file_bytes() { wc -c < "$1" | tr -d ' '; }

# digest of a tree: sorted "sha256  ./relative/path" lines, hashed once more
tree_digest() { (cd "$1" && find . -type f -print0 | sort -z | sha256_files | sha256_stdin); }
tree_files()  { (cd "$1" && find . -type f | wc -l | tr -d ' '); }
tree_bytes()  { (cd "$1" && find . -type f -print0 | xargs -0 cat | wc -c | tr -d ' '); }

# ---- arguments --------------------------------------------------------------------------------
MODE=write
TARBALL_ARG=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --tarball) shift; TARBALL_ARG="${1:-}"; [ -n "$TARBALL_ARG" ] || die "--tarball needs a file" ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) POS+=("$1") ;;
  esac
  shift
done
TAG="${POS[0]:-$PIN_TAG}"
COMMIT="${POS[1]:-$PIN_COMMIT}"
[ ${#POS[@]} -le 2 ] || die "usage: vendor_whisper.sh [--check] [--tarball FILE] [<tag> <commit>]"
[ ${#POS[@]} -ne 1 ] || die "give both <tag> and <commit>, or neither"

if [ "$COMMIT" = "$PIN_COMMIT" ] && [ "$TAG" = "$PIN_TAG" ]; then
  WANT_SHA="$PIN_TARBALL_SHA256"; WANT_TREE="$PIN_TREE_SHA256"
else
  WANT_SHA="${DV_WHISPER_SHA256:-}"; WANT_TREE=""
fi

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TP_DIR="$PKG_DIR/third_party"
DEST="$TP_DIR/whisper.cpp"
VENDORED_MD="$TP_DIR/VENDORED.md"
TARBALL_URL="$UPSTREAM/archive/refs/tags/$TAG.tar.gz"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vendor_whisper.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. obtain + verify the tarball -----------------------------------------------------------
if [ -n "$TARBALL_ARG" ]; then
  cp "$TARBALL_ARG" "$WORK/src.tar.gz"
else
  echo "downloading $TARBALL_URL"
  curl -fsSL --retry 3 -o "$WORK/src.tar.gz" "$TARBALL_URL"
fi
GOT_SHA="$(sha256_stdin < "$WORK/src.tar.gz")"
TARBALL_BYTES="$(file_bytes "$WORK/src.tar.gz")"
echo "tarball: $TARBALL_BYTES bytes, sha256 $GOT_SHA"

# decompress to a file first: piping into `git get-tar-commit-id` (which exits after the header)
# makes gzip die of SIGPIPE, which `set -o pipefail` reports as failure.
gzip -dc "$WORK/src.tar.gz" > "$WORK/src.tar"
GOT_COMMIT="$(git get-tar-commit-id < "$WORK/src.tar")" || die "archive has no commit id"
[ "$GOT_COMMIT" = "$COMMIT" ] || die "commit mismatch: archive is $GOT_COMMIT, expected $COMMIT"

DRIFT=0
if [ -z "$WANT_SHA" ]; then
  die "no pinned sha256 for $TAG/$COMMIT. Review the value above, then re-run with DV_WHISPER_SHA256=$GOT_SHA"
elif [ "$GOT_SHA" != "$WANT_SHA" ]; then
  if [ "${DV_WHISPER_ALLOW_TARBALL_DRIFT:-0}" = 1 ] && [ -n "$WANT_TREE" ]; then
    echo "WARNING: tarball sha256 differs from the pin (GitHub archive drift?); commit id matches." >&2
    echo "         continuing: the extracted tree digest must match PIN_TREE_SHA256." >&2
    DRIFT=1
  else
    die "tarball sha256 mismatch: got $GOT_SHA, expected $WANT_SHA"
  fi
fi

# ---- 2. extract + prune -----------------------------------------------------------------------
mkdir "$WORK/up" "$WORK/new"
tar -xf "$WORK/src.tar" -C "$WORK/up"
rm -f "$WORK/src.tar"
TOPS=("$WORK"/up/*)
[ ${#TOPS[@]} -eq 1 ] && [ -d "${TOPS[0]}" ] || die "unexpected archive layout"
SRC="${TOPS[0]}"

: > "$WORK/list"
for f in "${KEEP_FILES[@]}"; do
  [ -f "$SRC/$f" ] || die "allowlisted file missing upstream: $f (layout changed; update the allowlist)"
  echo "$f" >> "$WORK/list"
done
for d in "${KEEP_DIRS[@]}"; do
  [ -d "$SRC/$d" ] || die "allowlisted directory missing upstream: $d (layout changed; update the allowlist)"
  (cd "$SRC" && find "$d" -type f) >> "$WORK/list"
done
(cd "$SRC" && find ggml/src -maxdepth 1 -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.h' \)) >> "$WORK/list"
sort -u "$WORK/list" -o "$WORK/list"

(cd "$SRC" && tar -cf - -T "$WORK/list") | tar -xf - -C "$WORK/new"

NEW_DIGEST="$(tree_digest "$WORK/new")"
NEW_FILES="$(tree_files "$WORK/new")"
NEW_BYTES="$(tree_bytes "$WORK/new")"
GGML_VER="$(awk '/set\(GGML_VERSION_(MAJOR|MINOR|PATCH) /{gsub(/\)/,"",$2); v=v (v?".":"") $2} END{print v}' "$SRC/ggml/CMakeLists.txt")"
echo "pruned tree: $NEW_FILES files, $NEW_BYTES bytes, digest $NEW_DIGEST, ggml $GGML_VER"

if [ "$DRIFT" = 1 ] && [ "$NEW_DIGEST" != "$WANT_TREE" ]; then
  die "tree digest $NEW_DIGEST does not match PIN_TREE_SHA256 $WANT_TREE"
fi
if [ -n "$WANT_TREE" ] && [ "$NEW_DIGEST" != "$WANT_TREE" ]; then
  die "tree digest $NEW_DIGEST does not match PIN_TREE_SHA256 $WANT_TREE (script allowlist changed?)"
fi

# ---- 3. generated files -----------------------------------------------------------------------
BEGIN_MARK='<!-- BEGIN GENERATED (tool/vendor_whisper.sh) -->'
END_MARK='<!-- END GENERATED -->'

existing_date() {
  [ -f "$VENDORED_MD" ] || return 0
  if grep -q "$GOT_COMMIT" "$VENDORED_MD" && grep -q "$NEW_DIGEST" "$VENDORED_MD"; then
    sed -n 's/^| Vendored on | \([0-9-]*\) |$/\1/p' "$VENDORED_MD" | head -n1
  fi
}
VENDOR_DATE="${DV_VENDOR_DATE:-$(existing_date)}"
[ -n "$VENDOR_DATE" ] || VENDOR_DATE="$(date -u +%F)"

{
  echo "$BEGIN_MARK"
  echo "<!-- Do not edit between the markers; re-run the script. -->"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Upstream | $UPSTREAM (MIT) |"
  echo "| Tag | $TAG |"
  echo "| Commit | \`$GOT_COMMIT\` |"
  echo "| ggml version | $GGML_VER |"
  echo "| Tarball | $TARBALL_URL |"
  echo "| Tarball size | $TARBALL_BYTES bytes |"
  echo "| Tarball sha256 | \`$GOT_SHA\` |"
  echo "| Vendored on | $VENDOR_DATE |"
  echo "| Pruned tree | $NEW_FILES files, $NEW_BYTES bytes ($(awk -v b="$NEW_BYTES" 'BEGIN{printf "%.2f MiB", b/1048576}')) under \`third_party/whisper.cpp/\` |"
  echo "| Tree digest | \`$NEW_DIGEST\` |"
  echo
  echo "Tree digest = sha256 of the sorted \`sha256  ./path\` lines of the pruned tree"
  echo "(\`cd third_party/whisper.cpp && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256\`)."
  echo
  echo "### Pruning rules"
  echo
  echo "Kept (everything else from the tarball is dropped):"
  echo
  for f in "${KEEP_FILES[@]}"; do echo "- \`$f\`"; done
  for d in "${KEEP_DIRS[@]}"; do echo "- \`$d/\` (recursive)"; done
  echo "- \`ggml/src/*.{c,cpp,h}\` (top level of \`ggml/src\` only)"
  echo
  echo "Dropped, notably: \`examples/\`, \`tests/\`, \`bindings/\` (except the one template above), \`models/\`,"
  echo "\`samples/\` (except \`jfk.wav\`), \`scripts/\`, \`ci/\`, \`.github/\`, \`.devops/\`, \`grammars/\`, \`media/\`, docs and"
  echo "\`ggml/src/ggml-{cuda,hip,musa,vulkan,opencl,sycl,cann,hexagon,openvino,rpc,webgpu,zdnn,zendnn,et,virtgpu}\`."
  echo "\`ggml/src/ggml-cpu\`, \`ggml-metal\` and \`ggml-blas\` are kept whole. Selecting a pruned backend at configure time fails."
  echo "$END_MARK"
} > "$WORK/generated.md"

printf '%s\n' \
  '# Generated by tool/vendor_whisper.sh. The top-level whisper.cpp CMakeLists.txt' \
  '# configure_file()s bindings/javascript/package-tmpl.json into this file when it is the' \
  '# top-level project (ExternalProject builds); it is a build by-product, not source.' \
  'whisper.cpp/bindings/javascript/package.json' > "$WORK/gitignore"

compose_vendored_md() {  # $1 = output file
  if [ -f "$VENDORED_MD" ] && grep -qF "$BEGIN_MARK" "$VENDORED_MD" && grep -qF "$END_MARK" "$VENDORED_MD"; then
    awk -v gen="$WORK/generated.md" -v b="$BEGIN_MARK" -v e="$END_MARK" '
      $0==b { while ((getline line < gen) > 0) print line; skip=1; next }
      $0==e { skip=0; next }
      !skip { print }' "$VENDORED_MD" > "$1"
  else
    { echo "# Vendored: whisper.cpp"; echo; cat "$WORK/generated.md"; echo
      echo "## Local changes and upstream review"; echo; echo "_Not written yet._"; } > "$1"
  fi
}
compose_vendored_md "$WORK/VENDORED.md"

# ---- 4. check or install ----------------------------------------------------------------------
if [ "$MODE" = check ]; then
  rc=0
  [ -d "$DEST" ] || die "no committed tree at $DEST"
  diff -r "$WORK/new" "$DEST" >/dev/null || { echo "DIFF: pruned tree differs from $DEST"; diff -rq "$WORK/new" "$DEST" | head -20; rc=1; }
  cmp -s "$WORK/VENDORED.md" "$VENDORED_MD" || { echo "DIFF: generated block of VENDORED.md is stale"; rc=1; }
  cmp -s "$WORK/gitignore" "$TP_DIR/.gitignore" || { echo "DIFF: third_party/.gitignore differs"; rc=1; }
  [ $rc -eq 0 ] && echo "OK: committed tree reproduces byte for byte ($NEW_FILES files, digest $NEW_DIGEST)"
  exit $rc
fi

mkdir -p "$TP_DIR"
[ -n "$DEST" ] && [ "$(basename "$DEST")" = whisper.cpp ] || die "refusing to replace unexpected path"
rm -rf "$DEST"
mv "$WORK/new" "$DEST"
cp "$WORK/VENDORED.md" "$VENDORED_MD"
cp "$WORK/gitignore" "$TP_DIR/.gitignore"
echo "vendored $TAG ($GOT_COMMIT) into $DEST"
echo "next: run '$0 --check', update PIN_TREE_SHA256 if this is a new pin, and review VENDORED.md"
