#!/bin/sh
# AIS-42: AOT size delta and release-binary contents. Run from the spike root.
# Compiles three AOT snapshots into a temp dir, prints sizes and string probes.
set -eu
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
cat > bin/zz_default_dev.dart <<'DART'
import 'package:genkit/genkit.dart';
Future<void> main() async { final ai = Genkit(); await ai.shutdown(); }
DART
trap 'rm -rf "$OUT" bin/zz_default_dev.dart' EXIT
dart compile aot-snapshot bin/aot_genkit.dart -o "$OUT/genkit.aot" >/dev/null
dart compile aot-snapshot bin/aot_custom.dart -o "$OUT/custom.aot" >/dev/null
dart compile aot-snapshot bin/zz_default_dev.dart -o "$OUT/default.aot" >/dev/null
for f in custom genkit default; do
  printf '%-8s %10s bytes\n' "$f" "$(wc -c < "$OUT/$f.aot" | tr -d ' ')"
done
echo "delta genkit-custom: $(( $(wc -c < "$OUT/genkit.aot") - $(wc -c < "$OUT/custom.aot") )) bytes"
for f in genkit default; do
  printf '%s:' "$f"
  for k in /api/__quitquitquit /api/runAction GENKIT_RUNTIME_ID GENKIT_ENV CollectorHttpSink X-Goog-Api-Client OPENAI_API_KEY GEMINI_API_KEY chat/completions; do
    printf ' %s=%s' "$k" "$(strings "$OUT/$f.aot" | grep -c -- "$k" || true)"
  done
  echo
done
