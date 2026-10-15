// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

@TestOn('browser')
library;

import 'package:flutter_web_plugins/url_strategy.dart' as flutter_web;
import 'package:rohd_schematic_viewer/src/platform/url_strategy.dart';
import 'package:test/test.dart';

void main() {
  test('disables browser history in JavaScript and Wasm builds', () {
    configureUrlStrategyIfWeb();

    expect(flutter_web.urlStrategy, isNull);
  });
}
