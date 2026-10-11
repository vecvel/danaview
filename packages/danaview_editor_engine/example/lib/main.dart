// OWNER: ENG-09
//
// Example host of the editor engine plugin. One screen: the engine capabilities summary. It uses
// plain widgets (no Material chrome); it is a test host and is never shipped.

import 'package:flutter/widgets.dart';

import 'engine_host.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EngineExampleApp());
}

/// Colours of the example screen (solid surfaces, one low-opacity border).
abstract final class _Palette {
  static const background = Color(0xFF101114);
  static const surface = Color(0xFF1B1D22);
  static const border = Color(0x1FFFFFFF);
  static const text = Color(0xFFF2F3F5);
  static const muted = Color(0xFFA9ADB6);
}

/// The example app: shows what [probeEngine] reports.
class EngineExampleApp extends StatefulWidget {
  /// Creates the app; [report] replaces the live probe (widget tests).
  const EngineExampleApp({super.key, this.report});

  /// A preloaded report, or null to probe the engine.
  final Future<EngineReport>? report;

  @override
  State<EngineExampleApp> createState() => _EngineExampleAppState();
}

class _EngineExampleAppState extends State<EngineExampleApp> {
  late final Future<EngineReport> _report = widget.report ?? probeEngine(createExampleEngine());

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      title: 'Danaview engine example',
      color: _Palette.background,
      debugShowCheckedModeBanner: false,
      builder: (context, _) => ColoredBox(
        color: _Palette.background,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _Palette.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _Palette.border),
                    boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 16, offset: Offset(0, 6))],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: FutureBuilder<EngineReport>(
                      future: _report,
                      builder: (context, snapshot) => Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Editor engine',
                            style: TextStyle(color: _Palette.text, fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            snapshot.data?.summary ?? 'loading capabilities…',
                            key: const ValueKey('engine-summary'),
                            softWrap: true,
                            style: const TextStyle(color: _Palette.muted, fontSize: 14, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
