# MarkItDown for macOS

A native macOS app that wraps the [browser-only MarkItDown page](../browser-poc) in a
`WKWebView`. Pyodide (CPython on WebAssembly), its packages and the MarkItDown wheels are
bundled inside the app. Conversion runs on your Mac without a network connection, and your
files are never uploaded.

It is based on the original [MarkItDown repository](https://github.com/microsoft/markitdown)
and is distributed under the same [MIT License](../browser-poc/LICENSE).

## Install a downloaded build

The app is ad-hoc signed and not notarized, because that requires a paid Apple Developer
account. macOS therefore blocks it the first time you open a copy downloaded from the internet.

1. Unzip `MarkItDown-macOS.zip` and move `MarkItDown.app` to `/Applications`.
2. Open it once. macOS says it cannot verify the developer; click **Done**.
3. Open **System Settings → Privacy & Security**, scroll to *Security*, click **Open Anyway**
   next to the MarkItDown message and confirm with your password.

Alternatively, remove the quarantine flag in Terminal, then open the app normally:

```sh
xattr -dr com.apple.quarantine /Applications/MarkItDown.app
```

Only do this for a build you trust, for example one you built yourself from this folder.
Apps you build locally are not quarantined and open without these steps.

## Build

Requirements: macOS 12 or later, the Xcode Command Line Tools (`xcode-select --install`)
and `python3`. Xcode itself is not needed.

```sh
desktop-macos/build.sh
```

The script:

1. Downloads Pyodide 0.29.5, the Pyodide packages and the PyPI wheels the page uses, and
   checks every file against its published SHA-256 (`tools/prepare_web.py`). Downloads are
   cached in `build/cache`.
2. Generates a desktop version of `browser-poc/index.html` that loads everything from the
   app and uses native copy and save.
3. Compiles a universal binary (Apple silicon and Intel) with `swiftc` and draws the icon.
4. Runs a self-test that converts DOCX, PDF, XLSX, PPTX and HTML samples from
   `packages/markitdown/tests/test_files` and checks that network requests fail.
5. Signs the app ad hoc with the App Sandbox and writes `build/MarkItDown.app` and
   `build/MarkItDown-macOS.zip` (about 26 MB).

## Use

- Drop files on the window, click **Choose files**, use **File → Open…** (⌘O), or drop
  files on the Dock icon or choose **Open With → MarkItDown** in Finder.
- **Copy** puts the Markdown on the clipboard, and **Download .md** opens a save dialog.
- Links to the original project open in your default browser.

## Privacy and security

- **Bundled runtime:** the page, Pyodide and every wheel are served from inside the app
  through a private `markitdown://` URL scheme. Nothing is downloaded at run time.
- **Content Security Policy:** the page may only load scripts and data from `markitdown://app/`.
- **WebKit content blocker:** every `http`, `https`, `ws`, `wss` and `ftp` request from the
  page is blocked, even if the CSP were bypassed.
- **Converter worker:** after start-up, `fetch`, `XMLHttpRequest`, `WebSocket`,
  `EventSource` and `importScripts` are disabled, as in the browser version.
- **App Sandbox:** the app can only read files you choose, drop or open with it, and write
  where you save. WebKit requires the `network.client` entitlement to start its web content
  process even for local pages, so the network is blocked by the three layers above rather
  than by the sandbox.
- **No persistent data:** the web view uses a non-persistent data store, so no cookies,
  caches or storage are kept between launches.

## Development notes

- `Sources/main.swift` contains the whole app: window, menus, URL scheme handler, file
  open and save, and the JavaScript bridge.
- `tools/prepare_web.py` rewrites the browser page. When `browser-poc/index.html` changes,
  rebuild; the script stops with an error if a text it replaces is no longer found.
- To test a build without the GUI, run the app binary with `--self-test` followed by file
  paths. It prints the Markdown for each file and exits with a non-zero status on failure.
  A sandboxed build can only read files in its container, so `build.sh` runs the self-test
  before applying the sandbox signature.
