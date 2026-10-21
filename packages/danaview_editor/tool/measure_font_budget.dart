// OWNER: AIS-22
//
// Placeholder (D-33) created by AIS-01. AIS-22 replaces this file:
// the bundled-font size budget check (≤ 8 MB of non-CJK Noto, AI_STUDIO_PLAN D-60, AIS-22).
// Until then it only reports that it is not available yet.

import 'dart:io';

/// Exits with a notice until AIS-22 lands.
void main() {
  stderr.writeln('measure_font_budget is not available yet (AIS-22).');
  exitCode = 2;
}
