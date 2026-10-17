// OWNER: AI-08
//
// Model download consent (ARCH §16.3, §20.2; ai.md §5.5). `UserConsent.accepted(` may be called
// only in packages/danaview_editor/lib/src/editor/flows/captions/model_consent_view.dart (ARCH §4.2
// rule 8; enforced by danaview_editor's architecture test). Consent is per download; nothing is
// remembered.

import 'package:meta/meta.dart';

import '../catalog/speech_model_catalog.dart';

/// Exactly what the consent view displays. Compared again against the catalog and the server's
/// `x-linked-size` / `x-linked-etag` before any byte is written.
@immutable
final class ConsentDisclosure {
  /// The disclosure for downloading [spec] (plus the VAD model when [includesVad]).
  factory ConsentDisclosure.of(SpeechModelSpec spec, {required bool includesVad}) => ConsentDisclosure._(
        modelId: spec.id,
        fileName: spec.fileName,
        host: spec.host,
        cdnHost: SpeechModelCatalog.cdnHost,
        sha256: spec.sha256,
        totalBytes: spec.bytes + (includesVad ? SpeechModelCatalog.vad.bytes : 0),
        includesVad: includesVad,
      );

  /// A disclosure with arbitrary fields, to test how a downloader reacts to one that no longer
  /// equals the catalog (a changed catalog entry, a tampered value). Production code uses [of].
  @visibleForTesting
  const ConsentDisclosure.forTesting({
    required this.modelId,
    required this.fileName,
    required this.host,
    required this.cdnHost,
    required this.sha256,
    required this.totalBytes,
    required this.includesVad,
  });

  const ConsentDisclosure._({
    required this.modelId,
    required this.fileName,
    required this.host,
    required this.cdnHost,
    required this.sha256,
    required this.totalBytes,
    required this.includesVad,
  });

  /// Catalog id of the model.
  final String modelId;

  /// File name requested (the only thing the request names).
  final String fileName;

  /// Download host (`huggingface.co`).
  final String host;

  /// CDN host the download is redirected to (`hf.co`).
  final String cdnHost;

  /// SHA-256 the file must match.
  final String sha256;

  /// Bytes downloaded in total (model + VAD when needed).
  final int totalBytes;

  /// Whether the VAD model is part of this download.
  final bool includesVad;

  /// Whether this is exactly what the catalog entry [modelId] would disclose today. The downloader
  /// refuses anything else with `ModelDownloadFailureKind.consentMismatch` before the first request.
  bool get matchesCatalog {
    final spec = SpeechModelCatalog.byId(modelId);
    return spec != null && this == ConsentDisclosure.of(spec, includesVad: includesVad);
  }

  @override
  bool operator ==(Object other) =>
      other is ConsentDisclosure &&
      other.modelId == modelId &&
      other.fileName == fileName &&
      other.host == host &&
      other.cdnHost == cdnHost &&
      other.sha256 == sha256 &&
      other.totalBytes == totalBytes &&
      other.includesVad == includesVad;

  @override
  int get hashCode => Object.hash(modelId, fileName, host, cdnHost, sha256, totalBytes, includesVad);
}

/// The user's explicit agreement to one download.
@immutable
final class UserConsent {
  /// Constructed only by the consent view after the user taps "Download" (architecture test).
  const UserConsent.accepted(this.disclosure, {required this.acceptedAt});

  /// What the user saw.
  final ConsentDisclosure disclosure;

  /// When the user agreed.
  final DateTime acceptedAt;
}
