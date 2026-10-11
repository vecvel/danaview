import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_whisper/src/runtime/native_runtime.dart';
import 'package:vwish_whisper/src/runtime/vw_bindings.dart';
import 'package:vwish_whisper/vwish_whisper.dart';
import 'fake_vw_bindings.dart';

void main() {
  testWidgets('dbg', (tester) async {
    final fake = FakeVwBindings();
    final rt = NativeWhisperRuntime(bindings: fake, device: WhisperDeviceChannel(enabled: false));
    WhisperModel? m;
    print('a');
    unawaited(rt.loadModel('/m.bin').then((v) { m = v; }));
    print('b');
    fake.lastModel.state = VwModelState.ready;
    await tester.pump(const Duration(milliseconds: 50));
    print('c $m');
    final job = m!.transcribe(const WhisperTranscribeRequest(wavPath: 'w', language: 'en', threads: 2));
    print('d');
    await tester.pump();
    print('e');
    await tester.pump(const Duration(milliseconds: 250));
    print('f');
    await rt.dispose();
    print('g');
    for (var i = 0; i < 70; i++) { await tester.pump(const Duration(seconds: 1)); print('t$i'); }
    print('h');
  });
}
