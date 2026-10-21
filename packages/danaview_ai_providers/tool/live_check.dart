// OWNER: AIS-40
//
// Placeholder (D-33) created by AIS-01. AIS-40 replaces this file:
// the manual live-provider check (never run by CI; AI_STUDIO_PLAN §5.5 AIS-40).
// Until then it only reports that it is not available yet.

import 'dart:io';

/// Exits with a notice until AIS-40 lands.
void main() {
  stderr.writeln('live_check is not available yet (AIS-40).');
  exitCode = 2;
}
