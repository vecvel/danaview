import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import '../../test/support/editor_test_harness.dart';
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('probe', (t) async { final h = EditorTestHarness(); await h.pumpEditor(t); expect(1, 1); });
}
