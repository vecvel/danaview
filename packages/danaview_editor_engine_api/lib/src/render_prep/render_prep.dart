// OWNER: API-04
//
// Render prep (ARCH §10.3, §13.1, D-05, D-06): the text layout engine shared by the preview
// overlay, handles and export sprites; the sprite rasterizer; the `.vsprite` codec; the export
// sprite pre-pass.

library;

export 'sprite_prepass.dart';
export 'text_layout_engine.dart';
export 'text_sprite_rasterizer.dart';
export 'vsprite_codec.dart';
export 'zlib_stream.dart' show adler32, deflateZlib, inflateZlibStream;
