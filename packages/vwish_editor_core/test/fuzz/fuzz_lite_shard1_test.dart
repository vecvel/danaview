// OWNER: CORE-34
// fuzz-lite shard 2 of 4 (see fuzz_lite.dart).
@Tags(['fuzz-lite'])
library;

import 'package:test/test.dart';

import 'fuzz_lite.dart';

void main() => fuzzLiteShard(1);
