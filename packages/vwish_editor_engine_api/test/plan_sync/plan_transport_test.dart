// OWNER: API-02
//
// Plan transport (ARCH §11.1 rule 4): UTF-8 JSON round trips of plans, patches and transients,
// inline below and isolate above the size threshold with identical bytes, and ack decoding.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor_core/plan.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'support.dart';

RenderPlan compiled(int n, {int revision = 1}) {
  final p = project(n: n, revision: revision);
  return compilePlan(p, PlanTarget.preview, resolverOf(p), options: CompileOptions(stages: standardLoweringStages())).plan;
}

void main() {
  test('plan round trip; isolate and inline encodings are byte-identical', () async {
    final plan = compiled(5);
    final inline = await PlanTransport.encodePlan(plan);
    final isolate = await PlanTransport.encodePlan(plan, forceIsolate: true);
    expect(isolate, inline);
    expect(inline, PlanJson.encodePlanBytes(plan));
    expect(PlanTransport.decodePlan(inline), plan);
    expect(jsonDecode(utf8.decode(inline)), isA<Map<String, Object?>>(), reason: 'UTF-8 JSON');
  });

  test('large plans are encoded in an isolate (above the threshold)', () async {
    final plan = compiled(200);
    expect(PlanTransport.sizeOfPlan(plan), greaterThan(PlanTransport.isolateThreshold));
    final bytes = await PlanTransport.encodePlan(plan);
    expect(PlanTransport.decodePlan(bytes), plan);
    expect(PlanTransport.sizeOfPlan(compiled(2)), lessThanOrEqualTo(PlanTransport.isolateThreshold));
  });

  test('patch round trip applies like the original', () async {
    final a = compiled(4, revision: 1);
    final p = withOpacity(project(n: 4, revision: 1), 2, 0.5, revision: 2);
    final b = compilePlan(p, PlanTarget.preview, resolverOf(p), options: CompileOptions(stages: standardLoweringStages())).plan;
    final patch = diffPlans(a, b);
    expect(PlanTransport.sizeOfPatch(patch), greaterThan(0));
    final bytes = await PlanTransport.encodePatch(patch);
    expect(await PlanTransport.encodePatch(patch, forceIsolate: true), bytes);
    final decoded = PlanTransport.decodePatch(bytes);
    expect(decoded, patch);
    expect(applyPatch(a, decoded).layers, b.layers);
  });

  test('transient round trip (inline)', () {
    final p = project(revision: 1);
    final t = transientOf(p, 1, 0.4);
    final bytes = PlanTransport.encodeTransient(t);
    expect(PlanTransport.decodeTransient(bytes), t);
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    expect(json['item'], clipId(1));
    expect(json.containsKey('rev'), isFalse, reason: 'transients are never assigned a revision');
  });

  group('acks', () {
    test('decode', () {
      const ack = PlanAck(rev: 12, structural: true, applyMs: 37);
      final decoded = PlanTransport.decodeAck(PlanTransport.encodeAck(ack));
      expect((decoded.rev, decoded.structural, decoded.applyMs), (12, true, 37));
      final f = PlanTransport.ackOf(rev: 3, structural: false, applyMs: 0);
      expect((f.rev, f.structural, f.applyMs), (3, false, 0));
      expect(PlanTransport.decodeAckJson({'rev': 1, 'structural': false, 'applyMs': 4.0}).applyMs, 4);
    });

    test('malformed acks are FormatExceptions', () {
      Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
      expect(() => PlanTransport.decodeAck(b('not json')), throwsFormatException);
      expect(() => PlanTransport.decodeAck(b('[1]')), throwsFormatException);
      expect(() => PlanTransport.decodeAck(b('{"rev":"1","structural":true,"applyMs":1}')), throwsFormatException);
      expect(() => PlanTransport.decodeAck(b('{"rev":1,"applyMs":1}')), throwsFormatException);
      expect(() => PlanTransport.decodeAck(b('{"rev":1,"structural":true,"applyMs":1.5}')), throwsFormatException);
      expect(() => PlanTransport.decodeAck(b('{"rev":-1,"structural":true,"applyMs":1}')), throwsFormatException);
      expect(() => PlanTransport.ackOf(rev: 1, structural: true, applyMs: -2), throwsFormatException);
    });
  });
}
