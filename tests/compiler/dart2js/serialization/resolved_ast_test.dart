// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.serialization_resolved_ast_test;

import 'dart:async';
import 'package:async_helper/async_helper.dart';
import 'package:compiler/src/commandline_options.dart';
import 'package:compiler/src/compiler.dart';
import 'package:compiler/src/elements/elements.dart';
import 'package:compiler/src/filenames.dart';
import 'package:compiler/src/serialization/equivalence.dart';
import '../memory_compiler.dart';
import 'helper.dart';
import 'test_data.dart';
import 'test_helper.dart';


main(List<String> args) {
  Arguments arguments = new Arguments.from(args);
  asyncTest(() async {
    SerializedData serializedData =
        await serializeDartCore(arguments: arguments);
    if (arguments.filename != null) {
      Uri entryPoint = Uri.base.resolve(nativeToUriPath(arguments.filename));
      await check(serializedData, entryPoint);
    } else {
      Uri entryPoint = Uri.parse('memory:main.dart');
      // TODO(johnniwinther): Change to test all serialized resolved ast instead
      // only those used in the test.
      Test test = TESTS.last;
      await check(serializedData, entryPoint, test.sourceFiles);
    }
  });
}

Future check(
  SerializedData serializedData,
  Uri entryPoint,
  [Map<String, String> sourceFiles = const <String, String>{}]) async {

  Compiler compilerNormal = compilerFor(
      memorySourceFiles: sourceFiles,
      options: [Flags.analyzeAll]);
  compilerNormal.resolution.retainCachesForTesting = true;
  await compilerNormal.run(entryPoint);

  Compiler compilerDeserialized = compilerFor(
      memorySourceFiles: serializedData.toMemorySourceFiles(sourceFiles),
      resolutionInputs: serializedData.toUris(),
      options: [Flags.analyzeAll]);
  compilerDeserialized.resolution.retainCachesForTesting = true;
  await compilerDeserialized.run(entryPoint);

  checkAllResolvedAsts(compilerNormal, compilerDeserialized, verbose: true);
}

void checkAllResolvedAsts(
    Compiler compiler1,
    Compiler compiler2,
    {bool verbose: false}) {
  checkLoadedLibraryMembers(
      compiler1,
      compiler2,
      (Element member1) {
        return member1 is ExecutableElement &&
            compiler1.resolution.hasResolvedAst(member1);
      },
      checkResolvedAsts,
      verbose: verbose);
}


/// Check equivalence of [impact1] and [impact2].
void checkResolvedAsts(Compiler compiler1, Element member1,
                       Compiler compiler2, Element member2,
                       {bool verbose: false}) {
  if (!compiler2.serialization.isDeserialized(member2)) {
    return;
  }
  ResolvedAst resolvedAst1 = compiler1.resolution.getResolvedAst(member1);
  ResolvedAst resolvedAst2 = compiler2.serialization.getResolvedAst(member2);

  if (resolvedAst1 == null || resolvedAst2 == null) return;

  if (verbose) {
    print('Checking resolved asts for $member1 vs $member2');
  }

  testResolvedAstEquivalence(
      resolvedAst1, resolvedAst2, const CheckStrategy());
}
