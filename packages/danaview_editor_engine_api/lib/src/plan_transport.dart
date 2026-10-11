// OWNER: API-02
//
// Plan transport (ARCH §11.1 rule 4, §12.6, §18.1): plans, patches and transients cross the
// Pigeon control API as UTF-8 JSON bytes (core `PlanJson`), never as Pigeon object graphs.
//
// * Plans and patches above [PlanTransport.isolateThreshold] objects (layers + audio segments +
//   assets) are encoded in `Isolate.run`; smaller payloads are encoded inline because spawning
//   an isolate costs more than the encode (a one-item param patch is a few hundred bytes).
// * Transients are encoded inline (≤ 60 Hz, a handful of layers each).
// * Acks arrive as `PlanAckMsg` fields (ENG-02 maps them with [PlanTransport.ackOf]) or, from
//   test doubles and debug tooling, as a JSON object `{rev, structural, applyMs}`.

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:danaview_editor_core/plan.dart';

import 'preview.dart';

/// Encodes plan payloads for the platform channel and decodes acks (ARCH §11.1, API-02).
abstract final class PlanTransport {
  /// Payloads with more objects than this (layers + audio segments + assets, or upserts +
  /// removals for a patch) are encoded in `Isolate.run`.
  static const int isolateThreshold = 256;

  /// Number of plan objects that decides inline vs isolate encoding of [plan].
  static int sizeOfPlan(RenderPlan plan) => plan.layers.length + plan.audio.length + plan.assets.length;

  /// Number of patch objects that decides inline vs isolate encoding of [patch].
  static int sizeOfPatch(RenderPlanPatch patch) =>
      patch.layers.upsert.length +
      patch.layers.remove.length +
      patch.audio.upsert.length +
      patch.audio.remove.length +
      patch.assetUpserts.length +
      patch.assetRemovals.length;

  /// UTF-8 JSON of [plan]; encoded in an isolate above [isolateThreshold] objects (or always when
  /// [forceIsolate]).
  static Future<Uint8List> encodePlan(RenderPlan plan, {bool forceIsolate = false}) {
    if (forceIsolate || sizeOfPlan(plan) > isolateThreshold) {
      return Isolate.run(() => PlanJson.encodePlanBytes(plan), debugName: 'danaview.plan.encode');
    }
    return Future.value(PlanJson.encodePlanBytes(plan));
  }

  /// UTF-8 JSON of [patch]; encoded in an isolate above [isolateThreshold] objects (or always
  /// when [forceIsolate]).
  static Future<Uint8List> encodePatch(RenderPlanPatch patch, {bool forceIsolate = false}) {
    if (forceIsolate || sizeOfPatch(patch) > isolateThreshold) {
      return Isolate.run(() => PlanJson.encodePatchBytes(patch), debugName: 'danaview.patch.encode');
    }
    return Future.value(PlanJson.encodePatchBytes(patch));
  }

  /// UTF-8 JSON of [transient] (inline; transients are small and frequent).
  static Uint8List encodeTransient(PlanTransient transient) => PlanJson.encodeTransientBytes(transient);

  /// Decodes a plan (test doubles and debug tooling; engines decode natively).
  static RenderPlan decodePlan(Uint8List bytes) => PlanJson.decodePlanBytes(bytes);

  /// Decodes a patch (test doubles and debug tooling).
  static RenderPlanPatch decodePatch(Uint8List bytes) => PlanJson.decodePatchBytes(bytes);

  /// Decodes a transient (test doubles and debug tooling).
  static PlanTransient decodeTransient(Uint8List bytes) => PlanJson.decodeTransientBytes(bytes);

  /// The ack of the Pigeon `PlanAckMsg` fields. Throws [FormatException] for a negative [rev] or
  /// [applyMs].
  static PlanAck ackOf({required int rev, required bool structural, required int applyMs}) {
    if (rev < 0) throw FormatException('plan ack: negative rev $rev');
    if (applyMs < 0) throw FormatException('plan ack: negative applyMs $applyMs');
    return PlanAck(rev: rev, structural: structural, applyMs: applyMs);
  }

  /// Decodes an ack JSON object `{rev, structural, applyMs}` ([FormatException] when malformed).
  static PlanAck decodeAckJson(Map<String, Object?> json) {
    final rev = json['rev'];
    final structural = json['structural'];
    final applyMs = json['applyMs'];
    if (rev is! int) throw const FormatException('plan ack: "rev" must be an integer');
    if (structural is! bool) throw const FormatException('plan ack: "structural" must be a boolean');
    if (applyMs is! num || applyMs != applyMs.roundToDouble()) {
      throw const FormatException('plan ack: "applyMs" must be an integer');
    }
    return ackOf(rev: rev, structural: structural, applyMs: applyMs.toInt());
  }

  /// Decodes UTF-8 JSON ack bytes ([FormatException] when malformed).
  static PlanAck decodeAck(Uint8List bytes) {
    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw FormatException('plan ack: ${e.message}');
    }
    if (raw is! Map<String, Object?>) throw const FormatException('plan ack: expected a JSON object');
    return decodeAckJson(raw);
  }

  /// UTF-8 JSON of [ack] (fakes and debug tooling).
  static Uint8List encodeAck(PlanAck ack) =>
      Uint8List.fromList(utf8.encode(jsonEncode({'rev': ack.rev, 'structural': ack.structural, 'applyMs': ack.applyMs})));
}
