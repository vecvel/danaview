<!-- OWNER: UX-01 -->
# Architecture test fixtures (danaview_editor)

Negative and positive fixtures for `test/architecture/architecture_test.dart`. Every file carries a
`.fixture` suffix so neither the analyzer nor `flutter test` treats it as a source; the test feeds
each one to the scanner it targets and checks the exact number of violations (0 = a look-alike that
must pass).

| Folder | Rule |
|---|---|
| `material/` | ARCH §1.3 rule 1: no Material chrome (whole identifiers, code only) |
| `consent/` | ARCH §4.2 rule 8: `UserConsent.accepted(` only in the consent view |
| `rule7/` | ARCH §4.2 rule 7: engine API only, `danaview_features` only through chrome/orientation/storage, no router |
