// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const { once } = require('node:events');
const fs = require('node:fs');
const http = require('node:http');
const { createRequire } = require('node:module');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const manifest = require('../package.json');
const vsix = path.resolve(process.argv[2] ||
  path.join(root, 'build', `${manifest.name}-${manifest.version}.vsix`));
const reportDirectory = path.join(root, 'build', 'vsix-smoke');

function loadModule(filename, vscode) {
  const module = { exports: {} };
  const localRequire = createRequire(filename);
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
    module,
    exports: module.exports,
    require: name => {
      if (name === 'vscode') return vscode;
      if (name.startsWith('.')) {
        return loadModule(localRequire.resolve(name), vscode);
      }
      return localRequire(name);
    },
    Buffer,
    console,
    setTimeout,
    clearTimeout,
    __dirname: path.dirname(filename),
    __filename: filename,
  }, { filename });
  return module.exports;
}

function webviewHtml(extensionDirectory, resourceOrigin) {
  let provider;
  const disposable = { dispose() {} };
  const vscode = {
    Uri: { file: fsPath => ({ fsPath }) },
    commands: { registerCommand: () => disposable },
    window: {
      createOutputChannel: () => ({ appendLine() {} }),
      registerCustomEditorProvider: (_id, registeredProvider) => {
        provider = registeredProvider;
        return disposable;
      },
    },
  };
  const extension = loadModule(path.join(extensionDirectory, 'extension.js'), vscode);
  extension.activate({ extensionPath: extensionDirectory, subscriptions: [] });
  assert.ok(provider, 'The packaged extension must register its custom editor');
  const fixture = path.join(extensionDirectory, 'assets', 'rohd_schematic.json');
  return provider.getFlutterHtmlForWebview({
    cspSource: resourceOrigin,
    asWebviewUri: uri => new URL(
      path.relative(extensionDirectory, uri.fsPath).split(path.sep).join('/'),
      `${resourceOrigin}/`,
    ).href,
  }, vscode.Uri.file(fixture), fs.readFileSync(fixture, 'utf8'));
}

async function listen(server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return `http://127.0.0.1:${server.address().port}`;
}

async function exerciseRuntime(browser, documentOrigin, javascriptFallback) {
  const runtime = javascriptFallback ? 'javascript' : 'wasm';
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const diagnostics = [];
  const requests = new Set();
  page.setDefaultTimeout(60000);
  page.on('console', message => diagnostics.push(`${message.type()}: ${message.text()}`));
  page.on('pageerror', error => diagnostics.push(`pageerror: ${error.stack}`));
  page.on('request', request => requests.add(new URL(request.url()).pathname));
  try {
    // Only packaged resources and public fonts may make network requests.
    await page.route('**/*', route => {
      const url = new URL(route.request().url());
      if (url.hostname === '127.0.0.1') return route.continue();
      if (url.hostname === 'fonts.googleapis.com') {
        return route.fulfill({ contentType: 'text/css', body: '' });
      }
      if (url.origin === 'https://fonts.gstatic.com' &&
          route.request().method() === 'GET' && !url.search) {
        const headers = route.request().headers();
        delete headers.referer;
        return route.continue({ headers });
      }
      return route.abort('blockedbyclient');
    });
    await page.addInitScript(forceJavascript => {
      const state = window.__vsixSmoke = {
        firstFrame: false,
        layouts: 0,
        nodes: 0,
        historyWrites: 0,
      };
      window.addEventListener('flutter-first-frame', () => state.firstFrame = true);
      window.acquireVsCodeApi = () => ({
        postMessage() {},
        getState() { return null; },
        setState(value) { return value; },
      });
      for (const method of ['pushState', 'replaceState']) {
        const original = history[method].bind(history);
        history[method] = (...args) => {
          state.historyWrites++;
          return original(...args);
        };
      }
      let layout;
      Object.defineProperty(window, 'ElkLayoutOnly', {
        configurable: true,
        get: () => layout,
        set: implementation => {
          layout = async (...args) => {
            const result = await implementation(...args);
            if (!result.error && result.children?.length > 0) {
              state.layouts++;
              state.nodes = result.children.length;
            }
            return result;
          };
        },
      });
      if (forceJavascript) {
        // Fail capability probes, not compilation: CanvasKit still uses Wasm.
        WebAssembly.validate = () => false;
      }
    }, javascriptFallback);
    await page.goto(documentOrigin);
    await page.waitForFunction(() =>
      window.__vsixSmoke.firstFrame && window.__vsixSmoke.layouts > 0);
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await page.keyboard.press('Control+f');
    await page.getByRole('textbox', { name: 'Search blocks and wires' }).fill('clk');
    await page.keyboard.press('Escape');
    await page.getByRole('textbox', { name: 'Search blocks and wires' }).waitFor({ state: 'hidden' });

    const state = await page.evaluate(() => window.__vsixSmoke);
    assert.equal(state.historyWrites, 0, 'The webview must not modify browser history');
    assert.equal(
      requests.has('/flutter_web/main.dart.wasm'),
      !javascriptFallback,
      'Wasm entrypoint selection must match the tested runtime',
    );
    assert.equal(
      requests.has('/flutter_web/main.dart.js'),
      javascriptFallback,
      'JavaScript entrypoint selection must match the tested runtime',
    );
    assert.ok(!diagnostics.some(line => line.startsWith('pageerror:')), diagnostics.join('\n'));
    await page.screenshot({ path: path.join(reportDirectory, `${runtime}.png`) });
    console.log(`PASS ${runtime}: rendered schematic, completed ELK layout, opened wire search; no history writes.`);
    return { runtime, ...state };
  } finally {
    fs.writeFileSync(path.join(reportDirectory, `${runtime}.log`), diagnostics.join('\n'));
    await page.close();
  }
}

async function main() {
  fs.mkdirSync(reportDirectory, { recursive: true });
  for (const filename of ['results.json', 'wasm.png', 'javascript.png', 'wasm.log', 'javascript.log']) {
    fs.rmSync(path.join(reportDirectory, filename), { force: true });
  }
  const sha256 = createHash('sha256').update(fs.readFileSync(vsix)).digest('hex');
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'rohd-vsix-smoke-'));
  const servers = [];
  let browser;
  try {
    execFileSync('unzip', ['-q', vsix, '-d', temporaryDirectory]);
    const extensionDirectory = path.join(temporaryDirectory, 'extension');
    const mimeTypes = {
      '.html': 'text/html',
      '.js': 'application/javascript',
      '.mjs': 'application/javascript',
      '.wasm': 'application/wasm',
      '.json': 'application/json',
      '.png': 'image/png',
      '.svg': 'image/svg+xml',
      '.otf': 'font/otf',
    };
    let documentOrigin;
    const resources = http.createServer((request, response) => {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      const filename = path.resolve(extensionDirectory, `.${pathname}`);
      if (!filename.startsWith(`${extensionDirectory}${path.sep}`) ||
          !fs.existsSync(filename) || !fs.statSync(filename).isFile()) {
        response.writeHead(404);
        response.end(`Missing VSIX resource: ${pathname}`);
        return;
      }
      response.writeHead(200, {
        'Content-Type': mimeTypes[path.extname(filename)] || 'application/octet-stream',
        'Access-Control-Allow-Origin': documentOrigin,
      });
      fs.createReadStream(filename).pipe(response);
    });
    servers.push(resources);
    const resourceOrigin = await listen(resources);
    const html = webviewHtml(extensionDirectory, resourceOrigin);
    const document = http.createServer((_request, response) => {
      response.writeHead(200, { 'Content-Type': 'text/html' });
      response.end(html);
    });
    servers.push(document);
    documentOrigin = await listen(document);
    assert.notEqual(documentOrigin, resourceOrigin);

    browser = await chromium.launch({
      headless: true,
      ...(process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {}),
      args: ['--enable-unsafe-swiftshader'],
    });
    const results = [];
    for (const javascriptFallback of [false, true]) {
      results.push(await exerciseRuntime(browser, documentOrigin, javascriptFallback));
    }
    assert.equal(createHash('sha256').update(fs.readFileSync(vsix)).digest('hex'), sha256);
    fs.writeFileSync(path.join(reportDirectory, 'results.json'), JSON.stringify({
      vsix: path.basename(vsix), sha256, browser: browser.version(), results,
    }, null, 2));
    console.log(`Verified exact VSIX SHA-256: ${sha256}`);
  } finally {
    if (browser) await browser.close();
    await Promise.all(servers.map(server => new Promise(resolve => {
      server.close(resolve);
      server.closeAllConnections();
    })));
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
