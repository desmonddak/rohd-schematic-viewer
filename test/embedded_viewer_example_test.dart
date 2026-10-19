// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// embedded_viewer_example_test.dart
// Exercises the runnable README embedding example and its host services.
//
// 2026 October 18
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:rohd_devtools_widgets/rohd_devtools_widgets.dart'
    show LocalCrossProbeChannel, LocalCrossProbeService, RohdSourceFormat;
import 'package:rohd_hierarchy/rohd_hierarchy.dart'
    show BaseHierarchyAdapter, HierarchyOccurrence, NetlistHierarchyAdapter;
import 'package:rohd_schematic_viewer/schematic_viewer.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_native.dart';

import '../example/main.dart' show exampleNetlist;

Future<void> _setUpNativeLayoutHarness(
  WidgetTester tester,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
    if (message == null) {
      return null;
    }
    var assetKey = utf8.decode(
      message.buffer.asUint8List(
        message.offsetInBytes,
        message.lengthInBytes,
      ),
    );
    const packagePrefix = 'packages/rohd_schematic_viewer/';
    if (assetKey.startsWith(packagePrefix)) {
      assetKey = assetKey.substring(packagePrefix.length);
    }
    final asset = File(assetKey);
    if (!asset.existsSync()) {
      return null;
    }
    return ByteData.sublistView(Uint8List.fromList(asset.readAsBytesSync()));
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null),
  );
}

Future<void> _waitForCanvas(WidgetTester tester) async {
  for (var attempt = 0;
      attempt < 60 &&
          find.byType(SchematicCanvas).evaluate().isEmpty &&
          find.text('Error').evaluate().isEmpty;
      attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(SchematicCanvas), findsOneWidget);
}

void main() {
  tearDownAll(() => SchematicLayoutEngineNative().forceDispose());

  testWidgets('README embedding example uses host signal services after load',
      (tester) async {
    if (Platform.environment['RUN_NATIVE_LAYOUT_COVERAGE'] != 'true') {
      return;
    }

    await _setUpNativeLayoutHarness(tester);

    final outgoingSignals = <List<String>>[];
    final lookedUpSignals = <String>[];
    final incomingSignals = ValueNotifier<List<String>?>(null);
    addTearDown(incomingSignals.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmbeddedSchematicViewer.fromJson(
            schematicJson: exampleNetlist,
            themeMode: SchematicThemeMode.dark,
            expansionMode: SchematicExpansionMode.defaultView,
            hasExternalSignalListeners: true,
            onSendSignals: outgoingSignals.add,
            incomingSignalPaths: incomingSignals,
            signalValueLookupFn: (wireName) {
              lookedUpSignals.add(wireName);
              return (
                value: '1',
                computed: false,
                signalId: wireName,
              );
            },
          ),
        ),
      ),
    );

    await _waitForCanvas(tester);

    expect(find.byType(SchematicCanvas), findsOneWidget);
    expect(find.text('Error'), findsNothing);
    var canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    expect(canvas.layout.instances, isNotEmpty);
    expect(canvas.onSendSignals, isNotNull);
    expect(canvas.signalValueLookup, isNotNull);

    final value = canvas.signalValueLookup!('y');
    expect(value, (value: '1', computed: false, signalId: 'y'));
    expect(lookedUpSignals, ['y']);

    canvas.onSendSignals!(['ExampleTop/y']);
    expect(outgoingSignals, [
      ['ExampleTop/y'],
    ]);

    incomingSignals.value = ['ExampleTop/y'];
    await tester.pump();
    canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    expect(canvas.incomingSignalPaths?.value, ['ExampleTop/y']);
  });

  testWidgets('defers embedded layout until the schematic becomes visible',
      (tester) async {
    if (Platform.environment['RUN_NATIVE_LAYOUT_COVERAGE'] != 'true') {
      return;
    }

    await _setUpNativeLayoutHarness(tester);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmbeddedSchematicViewer.fromJson(
            schematicJson: exampleNetlist,
            isVisible: false,
          ),
        ),
      ),
    );
    expect(find.byType(SchematicCanvas), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmbeddedSchematicViewer.fromJson(
            schematicJson: exampleNetlist,
          ),
        ),
      ),
    );
    await _waitForCanvas(tester);

    final canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    expect(canvas.layout.instances, isNotEmpty);
    expect(find.text('Error'), findsNothing);
  });

  testWidgets(
      'incremental embedded loading fetches root and expanded module data',
      (tester) async {
    if (Platform.environment['RUN_NATIVE_LAYOUT_COVERAGE'] != 'true') {
      return;
    }

    await _setUpNativeLayoutHarness(tester);

    final fullNetlist = <String, dynamic>{
      'modules': <String, dynamic>{
        'Top': <String, dynamic>{
          'attributes': <String, dynamic>{'top': 1},
          'ports': <String, dynamic>{
            'a': <String, dynamic>{
              'direction': 'input',
              'bits': [1]
            },
            'b': <String, dynamic>{
              'direction': 'input',
              'bits': [2]
            },
            'y': <String, dynamic>{
              'direction': 'output',
              'bits': [3]
            },
          },
          'cells': <String, dynamic>{
            'u1': <String, dynamic>{
              'type': 'Child',
              'port_directions': <String, String>{
                'a': 'input',
                'b': 'input',
                'y': 'output',
              },
              'connections': <String, List<int>>{
                'a': [1],
                'b': [2],
                'y': [3],
              },
            },
          },
          'netnames': <String, dynamic>{
            'a': <String, dynamic>{
              'bits': [1]
            },
            'b': <String, dynamic>{
              'bits': [2]
            },
            'y': <String, dynamic>{
              'bits': [3]
            },
          },
        },
        'Child': <String, dynamic>{
          'attributes': <String, dynamic>{},
          'ports': <String, dynamic>{
            'a': <String, dynamic>{
              'direction': 'input',
              'bits': [1]
            },
            'b': <String, dynamic>{
              'direction': 'input',
              'bits': [2]
            },
            'y': <String, dynamic>{
              'direction': 'output',
              'bits': [3]
            },
          },
          'cells': <String, dynamic>{
            'and_gate': <String, dynamic>{
              'type': r'$_AND_',
              'port_directions': <String, String>{
                'A': 'input',
                'B': 'input',
                'Y': 'output',
              },
              'connections': <String, List<int>>{
                'A': [1],
                'B': [2],
                'Y': [3],
              },
            },
          },
          'netnames': <String, dynamic>{
            'a': <String, dynamic>{
              'bits': [1]
            },
            'b': <String, dynamic>{
              'bits': [2]
            },
            'y': <String, dynamic>{
              'bits': [3]
            },
          },
        },
      },
    };
    final fullModules = fullNetlist['modules'] as Map<String, dynamic>;
    const topKey = 'Top';
    final hierarchy = BaseHierarchyAdapter.fromTree(
      HierarchyOccurrence(
        name: 'top',
        definition: topKey,
        children: [
          HierarchyOccurrence(name: 'u1', definition: 'Child'),
        ],
      ),
    );

    final slimNetlist =
        jsonDecode(jsonEncode(fullNetlist)) as Map<String, dynamic>;
    final slimModules = slimNetlist['modules'] as Map<String, dynamic>;
    for (final moduleValue in slimModules.values) {
      final module = moduleValue as Map<String, dynamic>;
      final attributes =
          Map<String, dynamic>.from(module['attributes'] as Map? ?? {});
      attributes['netlistJsonMode'] = 'slim';
      module['attributes'] = attributes;
      module['netnames'] = <String, dynamic>{};
      final cells = module['cells'] as Map<String, dynamic>? ?? {};
      for (final cellValue in cells.values) {
        (cellValue as Map<String, dynamic>).remove('connections');
      }
    }

    final fetches = <String>[];
    final enrichedUpdates = <Map<String, dynamic>>[];
    final sentSignals = <List<String>>[];
    final sourceNavigations =
        <({RohdSourceFormat format, List<String> paths})>[];
    Future<Map<String, dynamic>?> fetchModule(String definitionName) async {
      fetches.add(definitionName);
      final fullModule = fullModules[definitionName];
      return fullModule == null
          ? null
          : <String, dynamic>{definitionName: fullModule};
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmbeddedSchematicViewer.fromNetlistMap(
            netlistJsonMap: slimNetlist,
            externalHierarchy: hierarchy,
            fetchModuleNetlist: fetchModule,
            onNetlistEnriched: enrichedUpdates.add,
            onSendSignals: sentSignals.add,
            onGoToSourceCallback: (format, paths) => sourceNavigations.add((
              format: format,
              paths: paths,
            )),
          ),
        ),
      ),
    );
    await _waitForCanvas(tester);

    var canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    expect(find.text('Error'), findsNothing);
    expect(fetches, [topKey]);
    canvas.onGoToSource!(RohdSourceFormat.rohd, ['Top/y']);
    expect(sourceNavigations, hasLength(1));
    expect(sourceNavigations.single.format, RohdSourceFormat.rohd);
    expect(sourceNavigations.single.paths, ['top/y']);
    canvas.onGoToSource!(
      RohdSourceFormat.rohd,
      ['Top', 'unmapped/signal'],
    );
    expect(sourceNavigations, hasLength(2));
    expect(sourceNavigations.last.paths, ['top', 'unmapped/signal']);
    canvas.onSendSignals!(['Top/y', 'Top', 'unmapped/signal']);
    expect(sentSignals, [
      ['top/y', 'top', 'unmapped/signal'],
    ]);

    final childModule = canvas.layout.instances.firstWhere((instance) {
      final definition = instance.definitionName;
      final module = definition == null
          ? null
          : slimModules[definition] as Map<String, dynamic>?;
      final cells = module?['cells'] as Map<String, dynamic>? ?? {};
      return definition != null &&
          definition != topKey &&
          instance.hasChildren &&
          cells.isNotEmpty;
    });

    final expand = canvas.onNodeToggle;
    expect(expand, isNotNull);
    var expansionComplete = false;
    final expansion = expand!(childModule.id).whenComplete(() {
      expansionComplete = true;
    });
    for (var attempt = 0; attempt < 600 && !expansionComplete; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(expansionComplete, isTrue);
    await expansion;
    canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    expect(
      canvas.layout.instances.any(
        (instance) => instance.id == childModule.id && instance.isExpanded,
      ),
      isTrue,
    );

    expect(fetches, [topKey, childModule.definitionName]);
    expect(enrichedUpdates, hasLength(1));
    final enrichedModules =
        enrichedUpdates.single['modules'] as Map<String, dynamic>;
    final enrichedChild =
        enrichedModules[childModule.definitionName] as Map<String, dynamic>;
    expect(
      (enrichedChild['cells'] as Map<String, dynamic>).values,
      isNotEmpty,
    );
    expect(
      (enrichedChild['cells'] as Map<String, dynamic>)
          .values
          .cast<Map<String, dynamic>>()
          .any((cell) => cell.containsKey('connections')),
      isTrue,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmbeddedSchematicViewer.fromNetlistMap(
            netlistJsonMap: slimNetlist,
            externalHierarchy: hierarchy,
            selectedModule: hierarchy.root.children.single,
            fetchModuleNetlist: fetchModule,
            onNetlistEnriched: enrichedUpdates.add,
            onSendSignals: sentSignals.add,
            onGoToSourceCallback: (format, paths) => sourceNavigations.add((
              format: format,
              paths: paths,
            )),
          ),
        ),
      ),
    );
    for (var attempt = 0;
        attempt < 60 &&
            (find.byType(SchematicCanvas).evaluate().isEmpty ||
                tester
                        .widget<SchematicCanvas>(
                          find.byType(SchematicCanvas),
                        )
                        .layout
                        .instances
                        .length !=
                    2);
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(SchematicCanvas), findsOneWidget);
    canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    expect(canvas.layout.instances, hasLength(2));
    expect(canvas.layout.edges, hasLength(3));
    canvas.onGoToSource!(RohdSourceFormat.rohd, ['Child/y']);
    expect(sourceNavigations.last.paths, ['top/u1/y']);
    expect(find.text('Error'), findsNothing);
  });

  testWidgets('FilterBank embedding cross-probes between viewer services',
      (tester) async {
    if (Platform.environment['RUN_NATIVE_LAYOUT_COVERAGE'] != 'true') {
      return;
    }

    await _setUpNativeLayoutHarness(tester);
    final channel = LocalCrossProbeChannel();
    final schematicService = LocalCrossProbeService(
      channel,
      source: 'schematic',
    );
    final waveformService = LocalCrossProbeService(
      channel,
      source: 'waveform',
    );
    addTearDown(waveformService.dispose);
    addTearDown(schematicService.dispose);
    addTearDown(channel.dispose);

    final filterBankJson =
        File('assets/FilterBank.rohd.json').readAsStringSync();
    final hierarchy = NetlistHierarchyAdapter.fromJson(filterBankJson);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmbeddedSchematicViewer.fromJson(
            schematicJson: filterBankJson,
            externalHierarchy: hierarchy,
            selectedModule: hierarchy.root,
            themeMode: SchematicThemeMode.dark,
            expansionMode: SchematicExpansionMode.defaultView,
            crossProbeService: schematicService,
          ),
        ),
      ),
    );
    await _waitForCanvas(tester);

    var canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    expect(canvas.layout.instances, isNotEmpty);
    expect(find.text('Error'), findsNothing);

    canvas.onSendSignals!(['FilterBank/out0']);
    expect(channel.lastSource, 'schematic');
    expect(channel.lastPaths, ['FilterBank/out0']);
    expect(waveformService.incomingSignals.value, ['FilterBank/out0']);
    expect(schematicService.incomingSignals.value, isNull);

    waveformService.send(
      ['FilterBank/out1'],
      source: 'waveform',
    );
    expect(schematicService.incomingSignals.value, ['FilterBank/out1']);
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    canvas = tester.widget<SchematicCanvas>(find.byType(SchematicCanvas));
    expect(canvas.incomingSignalPaths?.value, ['FilterBank/out1']);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Error'), findsNothing);
  });
}
