// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

test('extension opens and reloads netlists without whole-file reads', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'indexed-netlist-'));
  try {
    fs.mkdirSync(path.join(directory, 'flutter_web'));
    fs.writeFileSync(path.join(directory, 'flutter_web', 'index.html'),
      '<html><head><base href="/"></head><body></body></html>');
    const filename = path.join(directory, 'design.json');
    const content = Buffer.from('{"modules":{"Top":{"name":"\u03bb","ports":{}}}}');
    fs.writeFileSync(filename, content);
    let provider;
    let receive;
    let opens = 0;
    let closes = 0;
    let bytesRead = 0;
    const messages = [];
    const disposable = { dispose() {} };
    const vscode = {
      Uri: { file: fsPath => ({ fsPath, scheme: 'file' }) },
      commands: { registerCommand: () => disposable },
      window: {
        createOutputChannel: () => ({ appendLine() {} }),
        registerCustomEditorProvider: (_id, value) => {
          provider = value;
          return disposable;
        },
      },
      workspace: {
        fs: { readFile() { assert.fail('Whole-file read is forbidden'); } },
      },
    };
    const guardedFs = {
      ...fs,
      readFileSync(file, ...args) {
        assert.notEqual(file, filename, 'Netlist must never be read wholesale');
        return fs.readFileSync(file, ...args);
      },
      promises: {
        ...fs.promises,
        async open(file, flags) {
          assert.equal(file, filename, 'Range requests are scoped to the document');
          opens++;
          const handle = await fs.promises.open(file, flags);
          return {
            stat: () => handle.stat(),
            async read(...args) {
              assert.ok(args[2] <= 262144, 'Byte requests must be bounded');
              const result = await handle.read(...args);
              bytesRead += result.bytesRead;
              return result;
            },
            async close() { closes++; await handle.close(); },
          };
        },
      },
    };
    const module = { exports: {} };
    vm.runInNewContext(
      fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8'),
      {
        module, exports: module.exports, Buffer, console,
        require(name) {
          if (name === 'vscode') return vscode;
          if (name === 'fs') return guardedFs;
          if (name === './shared/module_info_helper') return {};
          return require(name);
        },
      },
    );
    module.exports.activate({ extensionPath: directory, subscriptions: [] });
    const uri = vscode.Uri.file(filename);
    const webview = {
      cspSource: 'test:',
      asWebviewUri: value => value.fsPath,
      onDidReceiveMessage: callback => { receive = callback; },
      postMessage: async message => { messages.push(message); return true; },
    };
    await provider.resolveCustomEditor(
      { uri }, { webview, onDidDispose() {} },
    );
    assert.equal(opens, 0);
    assert.ok(webview.html.includes('SCHEMATIC_INDEXED_FILE'));
    assert.ok(!webview.html.includes('SCHEMATIC_JSON_BASE64'));
    assert.ok(!webview.html.includes(content.toString()));

    const request = async fields => {
      await receive({ type: 'netlistRead', requestId: 1, ...fields });
      assert.equal(opens, closes, 'Each request must close its file handle');
      return messages.pop();
    };
    const metadata = await request({ start: 0, length: 0 });
    assert.equal(metadata.size, content.length);
    assert.equal(bytesRead, 0);
    const range = await request({
      start: 5, length: 17, revision: metadata.revision,
      path: '/not/the/document',
    });
    assert.deepEqual(Buffer.from(range.bytesBase64, 'base64'), content.subarray(5, 22));
    assert.equal(bytesRead, 17);
    for (const fields of [
      { start: -1, length: 1 },
      { start: 0, length: 262145 },
      { start: 0, length: -1 },
      { start: content.length + 1, length: 0 },
    ]) {
      assert.ok((await request(fields)).error.includes('Invalid netlist byte range'));
    }
    assert.equal(bytesRead, 17);

    fs.appendFileSync(filename, ' ');
    const changed = await request({
      start: 0, length: 1, revision: metadata.revision,
    });
    assert.ok(changed.error.includes('changed on disk'));
    await receive({ type: 'reload' });
    assert.equal(messages.pop().type, 'netlistFileChanged');
    assert.equal(bytesRead, 17);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
