<!-- OWNER: UX-24 -->
# Built-in looks

The 12 built-in looks of the Filters panel (Teal & Orange, Warm, Cool, Vivid, Matte, Fade, Mono, Noir,
Sepia, Vintage, Cinematic, Pastel; ARCH §6.5, §10.2) as `.vlut` v1 files, one per preset id:
`teal_orange`, `warm`, `cool`, `vivid`, `matte`, `fade`, `mono`, `noir`, `sepia`, `vintage`,
`cinematic`, `pastel` (lower-case, the extractor accepts `[a-z0-9_-]` only).

They are generated, never edited by hand: `dart run tool/gen_looks.dart` rewrites them,
`dart run tool/gen_looks.dart --check` fails when a committed file is out of date. Every table is
33x33x33 float16 RGB, red fastest, computed with plain arithmetic so the bytes are identical on every
host (`test/panels/color/gen_looks_test.dart` regenerates them and compares). At runtime the app
extracts a look to `<cache>/danaview/editor/looks/<id>.vlut` on first use (`BundledLookFiles`).
