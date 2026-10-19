// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// indexed_netlist_loader_test.dart
// Streaming JSON indexing and module connectivity regression tests.
//
// 2026 October
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/services/indexed_netlist_loader.dart';

Map<String, dynamic> _module(String type, {bool top = false}) => {
      'attributes': {
        if (top) 'top': 1,
        'description': 'Escaped "quotes", brackets } ], and \u03bb',
      },
      'ports': {
        'a': {
          'direction': 'input',
          'bits': [2, 3]
        },
        'z': {
          'direction': 'output',
          'bits': [4, 5]
        },
      },
      'cells': {
        'child': {
          'type': type,
          'port_directions': {'a': 'input', 'z': 'output'},
          'connections': {
            'a': [2, 3],
            'z': [4, 5]
          },
        },
      },
      'netnames': {
        'a': {
          'bits': [2, 3],
          'hide_name': 0
        },
      },
    };

void main() {
  final document = <String, dynamic>{
    'creator': 'ROHD',
    'version': '1',
    'files': ['source.dart'],
    'rootInstanceName': 'top',
    'modules': {
      'Top': _module('Child', top: true),
      'Child': _module(r'$buf'),
      'Unrelated': _module(r'$not'),
    },
  };

  test('indexes UTF-8 byte ranges across single-byte chunk boundaries',
      () async {
    final source =
        _TrackingSource(utf8.encode(jsonEncode(document)), chunkSize: 1);
    final loader = await IndexedNetlistLoader.index(source);
    final slim = loader.hierarchyJson;
    expect(loader.moduleNames, ['Top', 'Child', 'Unrelated']);
    expect(slim['files'], ['source.dart']);
    expect(slim['rootInstanceName'], 'top');
    final modules = slim['modules'] as Map<String, dynamic>;
    final child = modules['Child'] as Map<String, dynamic>;
    final cells = child['cells'] as Map<String, dynamic>;
    final cell = cells['child'] as Map<String, dynamic>;
    expect(cell.containsKey('connections'), isFalse);
    expect(cell['port_widths'], {'a': 2, 'z': 2});
    final originalModules = document['modules'] as Map<String, dynamic>;
    final originalChild = originalModules['Child'] as Map<String, dynamic>;
    final originalPorts = originalChild['ports'] as Map<String, dynamic>;
    expect(child['ports'], {
      for (final port in originalPorts.entries)
        port.key: {...port.value as Map<String, dynamic>, 'connected': true},
    });
    expect(child['netnames'], originalChild['netnames']);
    expect(source.reads, [(0, null)]);

    final progress = <(int, int)>[];
    var readyToDecode = false;
    final full = await loader.fetchModuleNetlist(
      'Child',
      onProgress: (bytes, total) => progress.add((bytes, total)),
      beforeDecode: () async {
        expect(progress.last.$1, progress.last.$2);
        readyToDecode = true;
      },
    );
    expect(readyToDecode, isTrue);
    expect(full, {'Child': (document['modules'] as Map)['Child']});
    final range = source.reads.last;
    expect(range.$2, isNotNull);
    final selectedText = utf8.decode(
      source.bytes.sublist(range.$1, range.$2),
    );
    expect(jsonDecode(selectedText), full['Child']);
    expect(selectedText, isNot(contains('Unrelated')));
    expect(source.reads, hasLength(2));
    expect(cell.containsKey('connections'), isFalse,
        reason:
            'The loader must not mutate or cache full data in its hierarchy');
  });

  test('accepts the ROHD netlist envelope', () async {
    final source =
        _TrackingSource(utf8.encode(jsonEncode({'netlist': document})));
    final loader = await IndexedNetlistLoader.index(source);
    expect(loader.hierarchyJson['creator'], 'ROHD');
    expect(await loader.fetchModuleNetlist('Top'),
        {'Top': (document['modules'] as Map)['Top']});
  });

  test('token runs preserve escapes, UTF-8, and offsets at every boundary',
      () async {
    final original = _module(r'$buf');
    original['attributes'] = {
      'text': 'A\u03bb\ud83d\ude00 "quoted" \\ escaped \n\t\r {}[],:',
      'slashes': r'\\\"',
      'boolean': true,
      'negative': -123,
      'decimal': 1.25e-12,
      'null': null,
    };
    final bytes = utf8.encode(jsonEncode({
      'modules': {'Top': original},
    }));
    for (var size = 1; size <= 64; size++) {
      final loader = await IndexedNetlistLoader.index(
        _TrackingSource(bytes, chunkSize: size),
      );
      expect(await loader.fetchModuleNetlist('Top'), {'Top': original},
          reason: 'chunk size $size');
      final modules = loader.hierarchyJson['modules'] as Map<String, dynamic>;
      expect((modules['Top'] as Map)['attributes'], original['attributes'],
          reason: 'chunk size $size');
    }
  });

  test('fast string scanning rejects raw controls and invalid UTF-8', () async {
    final prefix = utf8.encode('{"modules":{"Top":{"attributes":{"text":"');
    final suffix = utf8.encode('"}}}}');
    for (final invalid in [
      [0],
      [9],
      [10],
      [31],
      [0xc0, 0xaf],
      [0xff],
      [0xe2, 0x82],
    ]) {
      final bytes = [...prefix, ...invalid, ...suffix];
      for (final size in [1, bytes.length]) {
        await expectLater(
          IndexedNetlistLoader.index(
            _TrackingSource(bytes, chunkSize: size),
          ),
          throwsFormatException,
          reason: 'invalid bytes $invalid, chunk size $size',
        );
      }
    }
  });

  test('derives connected port markers even when cells precede ports',
      () async {
    final original = _module(r'$buf');
    final source = _TrackingSource(utf8.encode(jsonEncode({
      'modules': {
        'Reordered': {
          'cells': original['cells'],
          'ports': original['ports'],
          'netnames': original['netnames'],
        },
      },
    })));
    final loader = await IndexedNetlistLoader.index(source);
    final modules = loader.hierarchyJson['modules'] as Map<String, dynamic>;
    final module = modules['Reordered'] as Map<String, dynamic>;
    final ports = module['ports'] as Map<String, dynamic>;
    expect((ports['a'] as Map<String, dynamic>)['connected'], isTrue);
    expect((ports['z'] as Map<String, dynamic>)['connected'], isTrue);
    expect(source.reads, hasLength(3),
        reason: 'Only the two connection arrays are revisited');
  });

  test('coalesces concurrent requests but does not retain completed modules',
      () async {
    final source = _TrackingSource(utf8.encode(jsonEncode(document)));
    final loader = await IndexedNetlistLoader.index(source);
    final first = loader.fetchModuleNetlist('Child');
    final second = loader.fetchModuleNetlist('Child');
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(source.reads, hasLength(2));
    await loader.fetchModuleNetlist('Child');
    expect(source.reads, hasLength(3));
    expect(() => loader.fetchModuleNetlist('Missing'), throwsArgumentError);
  });

  test('cancels obsolete indexing without consuming the rest of the source',
      () async {
    final source = _TrackingSource(utf8.encode(jsonEncode(document)));
    await expectLater(
      IndexedNetlistLoader.index(
        source,
        shouldContinue: () => source.chunksRead < 3,
      ),
      throwsA(isA<Exception>()),
    );
    expect(source.chunksRead, 3);
  });

  test('reports monotonic scan progress and indexed module counts', () async {
    final bytes = utf8.encode(jsonEncode(document));
    final updates = <(int, int)>[];
    await IndexedNetlistLoader.index(
      _TrackingSource(bytes),
      onProgress: (bytes, modules) => updates.add((bytes, modules)),
    );
    expect(updates.first, (0, 0));
    expect(updates.last, (bytes.length, 3));
    for (var i = 1; i < updates.length; i++) {
      expect(updates[i].$1, greaterThanOrEqualTo(updates[i - 1].$1));
      expect(updates[i].$2, greaterThanOrEqualTo(updates[i - 1].$2));
    }
  });

  test('integer fast path preserves JSON scalar values and validation',
      () async {
    const values = [
      0,
      1,
      123456,
      999999999999999,
      1000000000000000,
      -1,
      1.5,
      1e30,
      true,
      false,
      null,
      '01',
    ];
    final loader = await IndexedNetlistLoader.index(
      _TrackingSource(utf8.encode(jsonEncode({
        'modules': {
          'Top': {
            'attributes': {
              for (var i = 0; i < values.length; i++) 'v$i': values[i],
            },
          },
        },
      }))),
    );
    final modules = loader.hierarchyJson['modules'] as Map<String, dynamic>;
    final top = modules['Top'] as Map<String, dynamic>;
    expect(top['attributes'], {
      for (var i = 0; i < values.length; i++) 'v$i': values[i],
    });
  });

  test('file source explicitly bounds every XFile read, including indexing',
      () async {
    final file = _RangeOnlyFile(
      '${' ' * (3 * 65536)}${jsonEncode(document)}',
    );
    final loader =
        await IndexedNetlistLoader.index(FileNetlistByteSource(file));
    expect(file.ranges, hasLength(4));
    final enriched = <String, dynamic>{};
    for (final name in loader.moduleNames) {
      enriched.addAll(await loader.fetchModuleNetlist(name));
    }
    expect(enriched, document['modules'],
        reason: 'On-demand module reads must reproduce the original netlist');
    expect(file.ranges.every((range) => range.$2 - range.$1 <= 65536), isTrue);
  });

  for (final invalid in [
    '{"modules":{"Top":{"cells":{"x":{"connections":{"a":[1,]}}}}}}',
    '{"modules":{"Top":{"cells":{"x":{"connections":{"a":[01]}}}}}}',
    r'{"modules":{"Top":{"cells":{"x":{"connections":{"a":["\uZZZZ"]}}}}}}',
    '{"modules":{"Top":{}}} trailing',
    '{"modules":{"Top":{}}',
    '{"modules":{"Top":[]}}',
    '{"modules":[{}]}',
    '{"modules":{}}',
  ]) {
    test(
        'rejects malformed JSON, including skipped connection values: $invalid',
        () async {
      await expectLater(
        IndexedNetlistLoader.index(
          _TrackingSource(utf8.encode(invalid), chunkSize: 3),
        ),
        throwsFormatException,
      );
    });
  }

  test('streams a large disk file and rereads only the requested module',
      () async {
    final directory = await Directory.systemTemp.createTemp('netlist-index-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/large.json');
    final output = await file.open(mode: FileMode.write);
    final bits = List.filled(16384, '2').join(',');
    await output.writeString('{"modules":{');
    for (var i = 0; i < 64; i++) {
      await output.writeString(
        '${i == 0 ? '' : ','}"M$i":{"ports":{},'
        r'"cells":{"gate":{"type":"$buf",'
        '"connections":{"A":[$bits]}}},"netnames":{}}',
      );
    }
    await output.writeString('}}');
    await output.close();

    final source = _CountingFileSource(FileNetlistByteSource(XFile(file.path)));
    final loader = await IndexedNetlistLoader.index(source);
    final size = await file.length();
    expect(size, greaterThan(2 * 1024 * 1024));
    expect(source.largestChunk, lessThanOrEqualTo(65536));
    expect(source.bytesRead, size);
    expect(jsonEncode(loader.hierarchyJson).length, lessThan(size ~/ 100));
    expect(source.reads, [(0, null)]);

    final full = await loader.fetchModuleNetlist('M37');
    expect(full.keys, ['M37']);
    expect(source.reads, hasLength(2));
    expect(source.bytesRead - size, lessThan(size ~/ 50));

    await file.writeAsString('changed');
    await expectLater(loader.fetchModuleNetlist('M0'), throwsFormatException);
  });
}

class _TrackingSource extends NetlistByteSource {
  _TrackingSource(this.bytes, {this.chunkSize = 11});

  final List<int> bytes;
  final int chunkSize;
  final List<(int, int?)> reads = [];
  int chunksRead = 0;

  @override
  Stream<List<int>> openRead([int start = 0, int? end]) async* {
    reads.add((start, end));
    final limit = end ?? bytes.length;
    for (var i = start; i < limit; i += chunkSize) {
      chunksRead++;
      yield bytes.sublist(i, (i + chunkSize).clamp(0, limit));
    }
  }
}

class _CountingFileSource extends NetlistByteSource {
  _CountingFileSource(this.source);

  final NetlistByteSource source;
  final List<(int, int?)> reads = [];
  int bytesRead = 0;
  int largestChunk = 0;

  @override
  Stream<List<int>> openRead([int start = 0, int? end]) async* {
    reads.add((start, end));
    await for (final chunk in source.openRead(start, end)) {
      bytesRead += chunk.length;
      if (chunk.length > largestChunk) {
        largestChunk = chunk.length;
      }

      yield chunk;
    }
  }
}

class _RangeOnlyFile extends XFile {
  _RangeOnlyFile(String json)
      : bytes = Uint8List.fromList(utf8.encode(json)),
        super('range-only');

  final Uint8List bytes;
  final List<(int, int)> ranges = [];

  @override
  Future<int> length() async => bytes.length;

  @override
  Future<DateTime> lastModified() async => DateTime.utc(2026);

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    expect(start, isNotNull);
    expect(end, isNotNull);
    ranges.add((start!, end!));
    expect(end - start, lessThanOrEqualTo(65536));
    yield Uint8List.sublistView(bytes, start, end);
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      throw StateError('Whole-file string reads are forbidden');

  @override
  Future<Uint8List> readAsBytes() async =>
      throw StateError('Whole-file byte reads are forbidden');
}
