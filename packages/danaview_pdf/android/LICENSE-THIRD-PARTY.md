<!-- OWNER: HOM-25 (HOM-28A..HOM-31A extend it if they add a library) -->
# Third-party licences (danaview_pdf, Android)

The Android build of `danaview_pdf` depends on the libraries below (Maven Central, resolved by Gradle; nothing
is vendored in this repository). They are the accepted Android PDF engine of HOM-27 (lead d9872042, ARCH D-98j).
HOM-25 uses them read-only (document facts, outline, text before Android 15); HOM-28A..HOM-31A write with them.
Binary distributions of the app list them on the app-level "Open source licences" screen.

| Library | Version | Licence | SHA-256 of the artifact (checked against the HOM-27 report) |
|---|---|---|---|
| `com.tom-roush:pdfbox-android` (AAR) | 2.0.27.0 | Apache-2.0 | `30277f879cfd571db2a137582c95516a0d4ea6778e945519bc58ca93d57d88c7` |
| `org.bouncycastle:bcprov-jdk15to18` | 1.72 | Bouncy Castle Licence (MIT) | `ea66ea8a450810b2193e8bf9a7ad3e46307c9896224c0f407d1b7d96ba1221cc` |
| `org.bouncycastle:bcpkix-jdk15to18` | 1.72 | Bouncy Castle Licence (MIT) | `d9b97477b72499bcee02f5a906510810257ff36a94bf69fbca0b1e65e7ffdb6e` |
| `org.bouncycastle:bcutil-jdk15to18` | 1.72 | Bouncy Castle Licence (MIT) | `d92184bdeb3105a11ad9e36acbd66b5f8eed091b08b9c8f3e2549e42b7f131f1` |

## PdfBox-Android (Apache-2.0)

Source: https://github.com/TomRoush/PdfBox-Android, an Android port of Apache PDFBox
(https://pdfbox.apache.org). Licensed under the Apache License, Version 2.0
(https://www.apache.org/licenses/LICENSE-2.0); the full licence text goes with the app's licence screen.

Attribution (from Apache PDFBox's NOTICE): "Apache PDFBox. Copyright 2014 The Apache Software Foundation.
This product includes software developed at The Apache Software Foundation (http://www.apache.org/)."

The AAR bundles resources with their own licences: the Liberation Sans fallback font (SIL Open Font
License 1.1), Adobe CMap and AFM resources and the Adobe Glyph List (BSD-style Adobe licences, as shipped
with Apache PDFBox).

## Bouncy Castle (MIT)

Source: https://www.bouncycastle.org. Used by PdfBox-Android for encrypted PDFs only.

```
Copyright (c) 2000 - 2022 The Legion of the Bouncy Castle Inc. (https://www.bouncycastle.org)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
