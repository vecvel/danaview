# `.vsprite` fixtures (API-04)

Shared by the Dart codec test (`test/render_prep/vsprite_codec_test.dart`) and the native
decoders (IOS-09 XCTest, AND-09 JUnit). Format: ARCH §10.3.

| File | What |
|---|---|
| `synthetic_plain_8x4.vsprite` | Deterministic premultiplied pattern, no glyph map, scale 1 |
| `synthetic_reveal_16x8.vsprite` | Same pattern with a glyph map (`x div 4`, `0xFFFF` where alpha is 0), scale 0.5 |
| `text_box_stroke_shadow.vsprite` | Figtree text with background box, outline and shadow, scale 1 |
| `text_typewriter_reveal.vsprite` | Figtree typewriter text with a glyph map, scale 1.5 |

`sprites.json` lists, per file: `width`, `height`, `scale` (f32), `reveal`, the Adler-32 of the
inflated RGBA bytes (`rgbaAdler32`) and of the inflated little-endian glyph bytes
(`glyphsAdler32`), and sample pixels (`rgba`, `glyph`). A native decoder passes when every field
matches. Decoders must inflate the first zlib stream to its end and start the second stream at
the next byte (no length fields).

Regenerate (only when the format or the generator changes):

```
VWISH_REGEN_SPRITE_FIXTURES=1 flutter test test/render_prep/sprite_fixtures_test.dart
```
