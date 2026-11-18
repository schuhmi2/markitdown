# MarkItDown in the browser: feasibility report and proof of concept

**Question:** can MarkItDown's basic mode run entirely in the user's browser, with no backend and
without uploading the file to a server?

**Answer: yes.** [`index.html`](index.html) is a single, self-contained static page that converts
files with the **unmodified** MarkItDown 0.1.9 running on [Pyodide](https://pyodide.org)
(CPython compiled to WebAssembly). File bytes go from the browser's File API to a Web Worker and
are processed in WebAssembly memory. They are never sent anywhere.

> This proof of concept is intended for a personal fork, not for submission to
> [microsoft/markitdown](https://github.com/microsoft/markitdown), whose README keeps applications
> out of the core repository. It sits outside `packages/` and changes nothing in the core package.

The original [MarkItDown repository](https://github.com/microsoft/markitdown) is licensed under
the [MIT License](LICENSE), reproduced here with its Microsoft copyright notice.

## Try it

Live on GitHub Pages: https://schuhmi2.github.io/markitdown/

**Download and open it locally (Windows, macOS, Linux):** download `MarkItDown-Web-<version>.zip`
from the [releases](https://github.com/schuhmi2/markitdown/releases), extract it and double-click
`index.html`. No server or installation is needed. Opening the page from disk was tested in
Chrome, Edge, Firefox and Safari (WebKit). The browser still downloads the Python runtime and
packages from the internet each session; your files stay on your computer.

To serve it locally:

```sh
python3 -m http.server 8000 --bind 127.0.0.1 -d browser-poc
# open http://127.0.0.1:8000 and drop files onto the page
```

Any static host (nginx, S3, GitHub Pages, an intranet share) can serve the page. There is no
build step and no npm.

The footer shows this page's version (`<span id="app-version">`) and the MarkItDown version that
Pyodide loaded. To build the release zip for the current version:

```sh
python3 browser-poc/make_release_zip.py   # writes browser-poc/dist/MarkItDown-Web-<version>.zip
```

## How it works

| Part of `index.html` | Role |
| --- | --- |
| Main inline script | UI: drag and drop, results, copy and download. Output is written with `textContent` only and is never rendered as HTML. |
| `worker-src` block | Web Worker started from a Blob URL. It loads Pyodide and MarkItDown, then **replaces `fetch`, `XMLHttpRequest`, `WebSocket`, `EventSource` and `importScripts` with functions that throw** before any file is accepted. |
| `python-src` block | Stubs the native-only modules, installs pinned wheels with `deps=False`, and calls `MarkItDown.convert_stream()`. |

### Required adaptations (no core changes)

| Dependency | Problem in WebAssembly | Workaround |
| --- | --- | --- |
| `magika` | Needs `onnxruntime`, which has no WebAssembly build | A stub reports "unsupported", so MarkItDown detects the type from the file extension and MIME type. Text encodings are still detected by `charset_normalizer`. Files **without an extension** are not detected. |
| `pdfplumber` → `pypdfium2` | Native PDFium | A stub is used. `pypdfium2` is only needed for page rendering, which MarkItDown doesn't use. |
| `lxml`, `pandas`, `numpy`, `pillow`, `cryptography` | Native code | Pyodide ships WebAssembly builds of these. |
| Everything else | Pure Python | Installed from PyPI as pinned wheels. |

## Results (headless Chromium, every file in `packages/markitdown/tests/test_files`)

All 38 fixtures in supported formats converted. Output is **identical to native CPython** running
this repository's source for 36 of them. The other two differ only as expected:

- **ZIP:** the header shows the file name instead of the full local path.
- **WAV:** natively the audio is transcribed by Google's online speech service, which the browser deliberately does not do.

| Format | Browser | Notes |
| --- | --- | --- |
| PDF (text-based) | ✅ | pdfminer.six and pdfplumber tables |
| DOCX, PPTX, XLSX, XLS | ✅ | Including equations, comments and charts |
| HTML, CSV (including Shift-JIS), JSON, TXT/MD | ✅ | |
| RSS/Atom XML, EPUB, IPYNB, Outlook MSG | ✅ | |
| ZIP | ✅ | Converts the supported files inside the archive |
| Scanned PDFs and images (OCR) | ❌ | Needs the OCR plugin and an LLM even natively. A local option would be Tesseract.js. |
| Image metadata | ❌ | Needs the `exiftool` program |
| Audio transcription | ❌ (by design) | Natively this uploads the audio to Google |
| YouTube, Wikipedia and Bing URLs; Azure Document Intelligence and Content Understanding; LLM captions | ❌ (by design) | These all send data to remote services |

**Performance:**
- **First visit:** about 35 MB uncompressed (Pyodide runtime, packages and wheels), cached by the browser afterwards. Start-up took about 11 s on this connection.
- **Conversion:** a 90 KB PDF took about 200 ms, a 270 KB PPTX about 35 ms, and a 730 KB ZIP of mixed files about 380 ms.

## Security properties

- **No upload path exists.** The server only serves one static file. It has no endpoint and never sees a
  document, so no parser handles untrusted files on the server. All parsing risk (zip bombs,
  malformed PDFs) stays inside the user's browser sandbox.
- **Network is locked down in two layers.**
  1. The Content Security Policy (CSP) is `default-src 'none'`. `connect-src` allows only the Pyodide CDN (`cdn.jsdelivr.net`) and PyPI (`pypi.org`, `files.pythonhosted.org`), which are needed to download the converter.
  2. After start-up, the worker removes every network API.

  The automated test confirmed:
  - zero network requests while all 39 fixture files were processed;
  - a `fetch` to another host from the page was blocked by the CSP;
  - `fetch` and `XMLHttpRequest` inside the worker threw.
- **No inline code runs without approval.** The single executable inline script and the stylesheet are allowed by
  SHA-256 hashes. `'unsafe-inline'` and `'unsafe-eval'` are not used; only `'wasm-unsafe-eval'` is allowed.
- **XSS:** Markdown output is shown as plain text and is never rendered as HTML.
- **Supply chain (PoC trade-off):** the runtime and wheels come from jsDelivr and PyPI. They only
  see download requests, never file contents. Wheel versions are pinned, and `loadPackage` checks
  Pyodide packages against the lock file's SHA-256. For production, self-host everything (see below).

## Limitations and next steps

- **Self-host for production.** Copy the Pyodide distribution and the pinned wheels to the same
  origin, verify each against its SHA-256, and tighten the CSP to `'self'`. This removes the
  dependency on third-party CDNs and allows intranet or offline use.
- **Use this fork's code.** The page installs `markitdown==0.1.9` from PyPI, which is the same
  version as this source tree. To ship fork changes, build a wheel (`uv build --wheel packages/markitdown`),
  host it next to the page, and replace the `markitdown==0.1.9` entry in `WHEELS` with the wheel's URL.
- **Memory and threading.** Very large files are limited by WebAssembly memory (about 2–4 GB), and conversion is single-threaded.
- **Optional extras:** a Service Worker for offline/PWA use, and Tesseract.js for local OCR.
- **Possible upstream change** (removes the `magika` stub): make `magika` an optional, lazily imported
  dependency of core MarkItDown.

## Editing `index.html`

The CSP allows the inline script and style by hash. After changing either one, regenerate the
hashes:

```sh
python3 - browser-poc/index.html <<'EOF'
import base64, hashlib, re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
h = lambda t: "sha256-" + base64.b64encode(hashlib.sha256(t.encode()).digest()).decode()
script = re.search(r"<script>(.*?)</script>", s, re.S).group(1)
style = re.search(r"<style>(.*?)</style>", s, re.S).group(1)
s = re.sub(r"script-src '[^']*'", f"script-src '{h(script)}'", s, count=1)
s = re.sub(r"style-src '[^']*'", f"style-src '{h(style)}'", s, count=1)
open(p, "w", encoding="utf-8").write(s)
EOF
```

## macOS desktop app

[`desktop-macos`](../desktop-macos) packages this page as an offline macOS app with Pyodide
and all wheels bundled. See its README for building and installing. The app takes its version
from the same `<span id="app-version">`, so change it in `index.html` for both.
