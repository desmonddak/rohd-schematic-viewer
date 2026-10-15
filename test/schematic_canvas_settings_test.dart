// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// schematic_canvas_settings_test.dart
// Tests painter settings and block rendering.
//
// 2026 October
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:rohd_schematic_viewer/src/schematic/schematic_canvas.dart';
import 'package:rohd_schematic_viewer/src/services/schematic_layout_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('width display setting invalidates the painter without a new layout',
      () {
    final viewTransform = ValueNotifier((
      scale: 1.0,
      offset: Offset.zero,
    ));
    final snapshotMode = ValueNotifier(false);
    final hoveredPort = ValueNotifier<({String? portId, bool isInterior})>((
      portId: null,
      isInterior: false,
    ));
    addTearDown(() {
      viewTransform.dispose();
      snapshotMode.dispose();
      hoveredPort.dispose();
    });

    final withoutWidths = SchematicPainter(
      layout: SchematicLayoutResult.empty(),
      viewTransform: viewTransform,
      snapshotMode: snapshotMode,
      hoveredBoundaryPortNotifier: hoveredPort,
      displaySignalWidths: false,
    );
    final withWidths = SchematicPainter(
      layout: SchematicLayoutResult.empty(),
      viewTransform: viewTransform,
      snapshotMode: snapshotMode,
      hoveredBoundaryPortNotifier: hoveredPort,
    );

    expect(withWidths.shouldRepaint(withoutWidths), isTrue);
  });

  for (final (theme, colors) in [
    ('light', SchematicColorScheme.light),
    ('dark', SchematicColorScheme.dark),
  ]) {
    for (final name in ['COMBINATIONAL', 'SEQUENTIAL', 'AND', 'FF']) {
      test('$name fill stays opaque in $theme theme', () async {
        expect(
          _pixelColor(await _paintNode(name, colors), 25, 25),
          colors.operatorFill.toARGB32(),
        );
      });
    }

    for (final name in ['COMBINATIONAL', 'SEQUENTIAL']) {
      for (final (hasChildren, labelColor) in [
        (false, 0xffffffff),
        (true, colors.nodeText.toARGB32()),
      ]) {
        test(
            '$name paints ${hasChildren ? 'boundary' : 'white'} port labels '
            'in $theme theme', () async {
          final pixels = await _paintNode(
            name,
            colors,
            ports: _namedPorts(),
            hasChildren: hasChildren,
          );

          for (final (label, left, top, right, bottom) in [
            ('input', 26, 40, 55, 59),
            ('output', 60, 70, 90, 89),
          ]) {
            var labelPixels = 0;
            for (var y = top; y < bottom; y++) {
              for (var x = left; x < right; x++) {
                if (_pixelColor(pixels, x, y) == labelColor) {
                  labelPixels++;
                }
              }
            }
            expect(labelPixels, greaterThan(0),
                reason: '$label label is visible');
          }
        });
      }
    }

    for (final name in ['AND', 'FF']) {
      test('$name still suppresses port labels in $theme theme', () async {
        final withoutPorts = await _paintNode(name, colors);
        final withPorts = await _paintNode(name, colors, ports: _namedPorts());
        expect(
          Uint8List.sublistView(withPorts),
          Uint8List.sublistView(withoutPorts),
        );
      });
    }
  }
}

List<SchematicPortData> _namedPorts() => [
      SchematicPortData(
        id: 'input',
        instanceId: 'node',
        x: 13,
        y: 40,
        width: 7,
        height: 13,
        name: 'IN',
        direction: 'INPUT',
        side: 'WEST',
      ),
      SchematicPortData(
        id: 'output',
        instanceId: 'node',
        x: 100,
        y: 70,
        width: 7,
        height: 13,
        name: 'OUT',
        direction: 'OUTPUT',
      ),
    ];

Future<ByteData> _paintNode(
  String name,
  SchematicColorScheme colors, {
  List<SchematicPortData> ports = const [],
  bool hasChildren = false,
}) async {
  final viewTransform = ValueNotifier((scale: 1.0, offset: Offset.zero));
  final snapshotMode = ValueNotifier(true);
  final hoveredPort = ValueNotifier<({String? portId, bool isInterior})>(
    (portId: null, isInterior: false),
  );
  addTearDown(() {
    viewTransform.dispose();
    snapshotMode.dispose();
    hoveredPort.dispose();
  });
  final painter = SchematicPainter(
    layout: SchematicLayoutResult(
      instances: [
        SchematicInstanceData(
          id: 'node',
          x: 20,
          y: 20,
          width: 80,
          height: 80,
          name: name,
          cls: 'Operator',
          hasChildren: hasChildren,
        ),
      ],
      ports: ports,
      edges: [],
      width: 120,
      height: 120,
    ),
    colorScheme: colors,
    viewTransform: viewTransform,
    snapshotMode: snapshotMode,
    hoveredBoundaryPortNotifier: hoveredPort,
  );
  final recorder = ui.PictureRecorder();
  painter.paint(ui.Canvas(recorder), const ui.Size(120, 120));
  final picture = recorder.endRecording();
  addTearDown(picture.dispose);
  final image = await picture.toImage(120, 120);
  addTearDown(image.dispose);
  final pixels = await image.toByteData();
  if (pixels == null) {
    throw StateError('Painter image did not return pixels');
  }
  return pixels;
}

int _pixelColor(ByteData pixels, int x, int y) {
  final offset = (y * 120 + x) * 4;
  return ui.Color.fromARGB(
    pixels.getUint8(offset + 3),
    pixels.getUint8(offset),
    pixels.getUint8(offset + 1),
    pixels.getUint8(offset + 2),
  ).toARGB32();
}
