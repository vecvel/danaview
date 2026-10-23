// OWNER: UX-42 (restored by FIX-LICENSES, owner decision 2026-10-16)
//
// Settings › About › Open-source licences (ARCH §17.1, §20.3, §20.4): a plain, custom page (no
// Material LicensePage) listing
// * the explicit notices of what the app bundles outside Dart packages ([danaviewBundledNotices]):
//   mpv/FFmpeg and the libraries built with them (LGPL and permissive), whisper.cpp/ggml (MIT), the
//   OpenAI Whisper and Silero VAD models (MIT), AndroidX Media3 (Apache-2.0), SQLite (public domain);
// * every [LicenseRegistry] entry: Flutter's own NOTICES (Dart packages, engine), the Figtree app
//   font ([registerDanaviewLicenses]) and the editor's content fonts (registered by the app router
//   through `registerContentFontLicenses`), all OFL-1.1.
// Each row opens in place to show its licence text.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../library/library_widgets.dart';

/// A licence notice the app shows by itself, for code or data that does not come with a Dart
/// package's LICENSE file (native libraries, models).
@immutable
final class BundledLicenseNotice {
  /// Creates a notice.
  const BundledLicenseNotice({required this.name, required this.licence, required this.usedFor, required this.text});

  /// The component's name as the page lists it.
  final String name;

  /// The licence, as an SPDX-style short name.
  final String licence;

  /// What the component does in Danaview, in plain words.
  final String usedFor;

  /// The notice: copyright lines and licence text or terms.
  final String text;
}

const String _mitPermission = 'Permission is hereby granted, free of charge, to any person obtaining a copy of this '
    'software and associated documentation files (the "Software"), to deal in the Software without restriction, '
    'including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or '
    'sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the '
    'following conditions:\n\n'
    'The above copyright notice and this permission notice shall be included in all copies or substantial portions '
    'of the Software.\n\n'
    'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED '
    'TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL '
    'THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF '
    'CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER '
    'DEALINGS IN THE SOFTWARE.';

const String _lgplTerms = 'This library is free software; you can redistribute it and/or modify it under the terms '
    'of the GNU Lesser General Public License as published by the Free Software Foundation; either version 2.1 of '
    'the License, or (at your option) any later version.\n\n'
    'This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the '
    'implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public '
    'License for more details: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html\n\n'
    'Danaview links this library dynamically and does not modify it.';

const String _apacheTerms = 'Licensed under the Apache License, Version 2.0 (the "License"); you may not use this '
    'file except in compliance with the License. You may obtain a copy of the License at '
    'https://www.apache.org/licenses/LICENSE-2.0\n\n'
    'Unless required by applicable law or agreed to in writing, software distributed under the License is '
    'distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See '
    'the License for the specific language governing permissions and limitations under the License.';

const String _playerLibraries = 'Video player (libmpv build of media_kit)';
const String _playerSource = 'Builds and their sources: https://github.com/media-kit/libmpv-darwin-build and '
    'https://github.com/media-kit/libmpv-android-video-build';

/// The explicit notices (ARCH §20.4 "Licences screen"), in page order.
const List<BundledLicenseNotice> danaviewBundledNotices = [
  BundledLicenseNotice(
    name: 'mpv',
    licence: 'LGPL-2.1-or-later',
    usedFor: 'Video player',
    text: 'Copyright © the mpv developers. https://mpv.io\n\n$_lgplTerms\n\n$_playerSource',
  ),
  BundledLicenseNotice(
    name: 'FFmpeg',
    licence: 'LGPL-2.1-or-later',
    usedFor: 'Video player: decoding and file formats',
    text: 'This software uses code of FFmpeg (https://ffmpeg.org) licensed under the LGPLv2.1, and its source can be '
        'downloaded at https://ffmpeg.org/download.html\n\n'
        'Copyright © the FFmpeg developers.\n\n$_lgplTerms\n\n$_playerSource',
  ),
  BundledLicenseNotice(
    name: 'FriBidi',
    licence: 'LGPL-2.1-or-later',
    usedFor: '$_playerLibraries: right-to-left subtitles',
    text: 'Copyright © the FriBidi authors. https://github.com/fribidi/fribidi\n\n$_lgplTerms',
  ),
  BundledLicenseNotice(
    name: 'libass',
    licence: 'ISC',
    usedFor: '$_playerLibraries: styled subtitles',
    text: 'Copyright © 2006-2016 libass contributors. https://github.com/libass/libass\n\n'
        'Permission to use, copy, modify, and distribute this software for any purpose with or without fee is hereby '
        'granted, provided that the above copyright notice and this permission notice appear in all copies.\n\n'
        'THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE '
        'INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR '
        'ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF '
        'USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF '
        'OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.',
  ),
  BundledLicenseNotice(
    name: 'dav1d',
    licence: 'BSD-2-Clause',
    usedFor: '$_playerLibraries: AV1 video',
    text: 'Copyright © 2018-2024, VideoLAN and dav1d authors. All rights reserved.\n\n'
        'Redistribution and use in source and binary forms, with or without modification, are permitted provided '
        'that the following conditions are met:\n\n'
        '1. Redistributions of source code must retain the above copyright notice, this list of conditions and the '
        'following disclaimer.\n'
        '2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and '
        'the following disclaimer in the documentation and/or other materials provided with the distribution.\n\n'
        'THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED '
        'WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A '
        'PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY '
        'DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, '
        'PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) '
        'HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING '
        'NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE '
        'POSSIBILITY OF SUCH DAMAGE.',
  ),
  BundledLicenseNotice(
    name: 'FreeType',
    licence: 'FTL',
    usedFor: '$_playerLibraries: subtitle fonts',
    text: 'Portions of this software are copyright © The FreeType Project (https://freetype.org). All rights '
        'reserved.\n\nUsed under the FreeType License: https://freetype.org/license.html',
  ),
  BundledLicenseNotice(
    name: 'HarfBuzz',
    licence: 'MIT',
    usedFor: '$_playerLibraries: subtitle text shaping',
    text: 'Copyright © the HarfBuzz authors. https://github.com/harfbuzz/harfbuzz\n\n'
        'Permission is hereby granted, without written agreement and without license or royalty fees, to use, copy, '
        'modify, and distribute this software and its documentation for any purpose, provided that the above '
        'copyright notice and the following two paragraphs appear in all copies of this software.\n\n'
        'IN NO EVENT SHALL THE COPYRIGHT HOLDER BE LIABLE TO ANY PARTY FOR DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR '
        'CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF THE COPYRIGHT '
        'HOLDER HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.\n\n'
        'THE COPYRIGHT HOLDER SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED '
        'WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON '
        'AN "AS IS" BASIS, AND THE COPYRIGHT HOLDER HAS NO OBLIGATION TO PROVIDE MAINTENANCE, SUPPORT, UPDATES, '
        'ENHANCEMENTS, OR MODIFICATIONS.',
  ),
  BundledLicenseNotice(
    name: 'libpng',
    licence: 'libpng-2.0',
    usedFor: '$_playerLibraries: images',
    text: 'Copyright © 1995-2024 The PNG Reference Library Authors.\n\n'
        'Used under the PNG Reference Library License version 2: http://www.libpng.org/pub/png/src/libpng-LICENSE.txt',
  ),
  BundledLicenseNotice(
    name: 'libxml2',
    licence: 'MIT',
    usedFor: '$_playerLibraries: streaming playlists',
    text: 'Copyright © 1998-2012 Daniel Veillard. All Rights Reserved.\n\n$_mitPermission',
  ),
  BundledLicenseNotice(
    name: 'Mbed TLS',
    licence: 'Apache-2.0',
    usedFor: '$_playerLibraries: secure streams',
    text: 'Copyright The Mbed TLS Contributors.\n\n$_apacheTerms',
  ),
  BundledLicenseNotice(
    name: 'uchardet',
    licence: 'MPL-1.1',
    usedFor: '$_playerLibraries: subtitle character sets',
    text: 'Copyright © the uchardet authors and the Mozilla Foundation. '
        'https://www.freedesktop.org/wiki/Software/uchardet/\n\n'
        'The contents of this library are subject to the Mozilla Public License Version 1.1: '
        'https://www.mozilla.org/MPL/1.1/ Software distributed under the License is distributed on an "AS IS" '
        'basis, WITHOUT WARRANTY OF ANY KIND, either express or implied.',
  ),
  BundledLicenseNotice(
    name: 'whisper.cpp and ggml',
    licence: 'MIT',
    usedFor: 'Auto captions on iPhone, iPad and Android: speech recognition',
    text: 'Copyright © 2023-2026 The ggml authors. https://github.com/ggml-org/whisper.cpp\n\n$_mitPermission',
  ),
  BundledLicenseNotice(
    name: 'OpenAI Whisper speech models',
    licence: 'MIT',
    usedFor: 'Auto captions on iPhone, iPad and Android; downloaded only if you use it',
    text: 'Copyright © 2022 OpenAI. https://github.com/openai/whisper\n\n$_mitPermission',
  ),
  BundledLicenseNotice(
    name: 'Silero VAD',
    licence: 'MIT',
    usedFor: 'Auto captions on iPhone, iPad and Android: finds speech; downloaded only if you use it',
    text: 'Copyright © 2020-present Silero Team. https://github.com/snakers4/silero-vad\n\n$_mitPermission',
  ),
  BundledLicenseNotice(
    name: 'AndroidX Media3',
    licence: 'Apache-2.0',
    usedFor: 'Video editor on Android: preview and export',
    text: 'Copyright © The Android Open Source Project. https://github.com/androidx/media\n\n$_apacheTerms',
  ),
  // D-7: the app bundles SQLite through sqlite3_flutter_libs (whose own MIT licence reaches the page
  // through LicenseRegistry with the other Dart packages).
  BundledLicenseNotice(
    name: 'SQLite',
    licence: 'Public domain',
    usedFor: 'Library: Danaview folders and files',
    text: 'SQLite is in the public domain: its authors have dedicated the code to the public domain. '
        'https://sqlite.org/copyright.html',
  ),
];

/// The [LicenseRegistry] package name of the app's own interface font.
const String figtreeAppFontLicensePackage = 'Figtree (app font)';

/// Asset key of the Figtree OFL text bundled by danaview_ui_kit.
const String figtreeAppFontLicenseAsset = 'packages/danaview_ui_kit/fonts/OFL.txt';

bool _registered = false;

/// Adds the Figtree app font's OFL-1.1 text to [LicenseRegistry]. The app router calls it (with the
/// editor's `registerContentFontLicenses`) before showing the licences page. Safe to call more than
/// once.
void registerDanaviewLicenses({AssetBundle? bundle}) {
  if (_registered) return;
  _registered = true;
  final assets = bundle ?? rootBundle;
  LicenseRegistry.addLicense(() async* {
    final String text;
    try {
      text = await assets.loadString(figtreeAppFontLicenseAsset);
    } catch (_) {
      return;
    }
    yield LicenseEntryWithLineBreaks(const [figtreeAppFontLicensePackage], text);
  });
}

/// One row of the page: a component and the text of its licence(s).
@immutable
final class LicenseListItem {
  /// Creates a row.
  const LicenseListItem({required this.name, required this.subtitle, required this.text});

  /// The component name.
  final String name;

  /// Licence and use, or the number of licences.
  final String subtitle;

  /// The full notice.
  final String text;
}

/// Groups registry [entries] by package, sorted by name ignoring case. Packages whose name is one
/// of [danaviewBundledNotices] are left out (the explicit notice already lists them).
List<LicenseListItem> groupLicenseEntries(Iterable<LicenseEntry> entries) {
  final explicit = {for (final n in danaviewBundledNotices) n.name.toLowerCase()};
  final texts = <String, List<String>>{};
  for (final entry in entries) {
    final text = entry.paragraphs.map((p) => '${'  ' * p.indent.clamp(0, 8)}${p.text}').join('\n\n').trim();
    if (text.isEmpty) continue;
    for (final package in entry.packages) {
      if (explicit.contains(package.toLowerCase())) continue;
      final list = texts.putIfAbsent(package, () => <String>[]);
      if (!list.contains(text)) list.add(text);
    }
  }
  final names = texts.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final name in names)
      LicenseListItem(
        name: name,
        subtitle: _registrySubtitle(name, texts[name]!.length),
        text: texts[name]!.join('\n\n────────\n\n'),
      ),
  ];
}

String _registrySubtitle(String name, int count) {
  if (name.endsWith('(app font)') || name.endsWith('content font)')) return 'OFL-1.1 · Font';
  return count == 1 ? '1 licence' : '$count licences';
}

/// The open-source licences page (Settings › About › Open-source licences).
class DanaviewLicensesScreen extends StatefulWidget {
  /// Creates the page; [licenseSource] defaults to [LicenseRegistry.licenses] (tests pass their own).
  const DanaviewLicensesScreen({super.key, required this.onBack, this.licenseSource});

  /// Leaves the page.
  final VoidCallback onBack;

  /// Where the registry entries come from.
  final Stream<LicenseEntry> Function()? licenseSource;

  @override
  State<DanaviewLicensesScreen> createState() => _DanaviewLicensesScreenState();
}

class _DanaviewLicensesScreenState extends State<DanaviewLicensesScreen> {
  static final List<LicenseListItem> _bundled = [
    for (final n in danaviewBundledNotices)
      LicenseListItem(name: n.name, subtitle: '${n.licence} · ${n.usedFor}', text: n.text),
  ];

  final List<LicenseEntry> _entries = [];
  List<LicenseListItem> _registry = const [];
  StreamSubscription<LicenseEntry>? _subscription;
  bool _loading = true;
  final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    final source = widget.licenseSource ?? () => LicenseRegistry.licenses;
    try {
      _subscription = source().listen(
        _entries.add,
        onError: (Object _) {},
        onDone: _finish,
        cancelOnError: false,
      );
    } catch (_) {
      _loading = false;
    }
  }

  void _finish() {
    if (!mounted) return;
    setState(() {
      _registry = groupLicenseEntries(_entries);
      _loading = false;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _toggle(String key) => setState(() => _open.contains(key) ? _open.remove(key) : _open.add(key));

  @override
  Widget build(BuildContext context) {
    final items = <Widget Function()>[
      () => const _Intro(),
      () => const DanaviewLibrarySectionHeader('Included in Danaview', topSpacing: DanaviewSpacing.xl),
      for (final item in _bundled) () => _row('bundled:${item.name}', item),
      () => const DanaviewLibrarySectionHeader('Fonts and Flutter packages'),
      if (_loading)
        () => const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: DanaviewSpacing.md),
              child: Text('Loading the package licences…', style: DanaviewTextStyles.caption),
            )
      else if (_registry.isEmpty)
        () => const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: DanaviewSpacing.md),
              child: Text('No package licences were found.', style: DanaviewTextStyles.caption),
            ),
      for (final item in _registry) () => _row('package:${item.name}', item),
    ];

    return Scaffold(
      backgroundColor: DanaviewColors.background,
      body: DanaviewLibraryFrame(
        topBar: DanaviewLibraryTopBar(title: 'Open-source licences', onBack: widget.onBack),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final insets = DanaviewSpacing.pageInsets(constraints.maxWidth);
            return ListView.builder(
              padding: insets.copyWith(
                top: DanaviewSpacing.lg,
                bottom: MediaQuery.paddingOf(context).bottom + DanaviewSpacing.xxl,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => items[index](),
            );
          },
        ),
      ),
    );
  }

  Widget _row(String key, LicenseListItem item) {
    final open = _open.contains(key);
    return _LicenseRow(key: ValueKey(key), item: item, open: open, onTap: () => _toggle(key));
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        'Danaview is built with open-source software, fonts and models. Each one is listed here with its '
        'licence. Tap one to read it.',
        style: DanaviewTextStyles.bodySecondary.copyWith(height: 1.45),
      ),
    );
  }
}

class _LicenseRow extends StatelessWidget {
  const _LicenseRow({super.key, required this.item, required this.open, required this.onTap});

  final LicenseListItem item;
  final bool open;
  final VoidCallback onTap;

  static const TextStyle _textStyle = TextStyle(fontSize: 13, height: 1.5, color: DanaviewColors.textSecondary);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One node: the row's button with its expanded state ("mpv, LGPL… · Video player, collapsed").
        MergeSemantics(
          child: Semantics(
            expanded: open,
            child: DanaviewLibraryRow(
              title: item.name,
              titleMaxLines: 2,
              subtitle: item.subtitle,
              subtitleMaxLines: 3,
              trailing: Padding(
                padding: const EdgeInsets.all(DanaviewSpacing.sm),
                child: Icon(
                  open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 22,
                  color: DanaviewColors.textMuted,
                ),
              ),
              onTap: onTap,
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, DanaviewSpacing.xs, 12, DanaviewSpacing.md),
            child: Text(item.text, style: _textStyle),
          ),
        const DanaviewRowDivider(indent: 12),
      ],
    );
  }
}
