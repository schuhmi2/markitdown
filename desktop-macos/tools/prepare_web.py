#!/usr/bin/env python3
"""Build the offline web bundle for the macOS app.

Reads ../browser-poc/index.html, downloads the Pyodide runtime, the Pyodide
packages it loads and the PyPI wheels it installs (every file verified against
its published SHA-256), and writes a desktop variant of the page that loads
everything from the app bundle instead of the network.
"""

import argparse
import ast
import base64
import hashlib
import json
import re
import shutil
import sys
import urllib.request
from pathlib import Path

PYODIDE_VERSION = "0.29.5"
PYODIDE_CDN = f"https://cdn.jsdelivr.net/pyodide/v{PYODIDE_VERSION}/full/"
CORE_FILES = ["pyodide.js", "pyodide.asm.js", "pyodide.asm.wasm", "python_stdlib.zip", "pyodide-lock.json"]
APP_ORIGIN = "markitdown://app/"

HERE = Path(__file__).resolve().parent
SOURCE_PAGE = HERE.parent.parent / "browser-poc" / "index.html"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url, cache, expected_sha=None):
    """Download url into the cache directory, reusing a verified cached copy."""
    target = cache / url.rsplit("/", 1)[1]
    if target.exists() and (expected_sha is None or sha256(target.read_bytes()) == expected_sha):
        return target.read_bytes()
    print(f"  downloading {url}", file=sys.stderr)
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if expected_sha is not None and sha256(data) != expected_sha:
        raise SystemExit(f"SHA-256 mismatch for {url}")
    target.write_bytes(data)
    return data


def python_lists(page):
    """Return PYODIDE_PACKAGES and WHEELS from the inline Python source."""
    source = re.search(r'<script type="text/x-python" id="python-src">(.*?)</script>', page, re.S).group(1)
    values = {}
    for node in ast.parse(source).body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in ("PYODIDE_PACKAGES", "WHEELS"):
                values[node.targets[0].id] = ast.literal_eval(node.value)
    return values["PYODIDE_PACKAGES"], values["WHEELS"]


def bundle_pyodide(packages, out, cache):
    pyodide_dir = out / "pyodide"
    pyodide_dir.mkdir(parents=True)
    for name in CORE_FILES:
        (pyodide_dir / name).write_bytes(fetch(PYODIDE_CDN + name, cache))

    lock = json.loads((pyodide_dir / "pyodide-lock.json").read_text())["packages"]
    needed, queue = set(), [p.lower() for p in packages]
    while queue:
        name = queue.pop()
        if name not in needed:
            needed.add(name)
            queue.extend(d.lower() for d in lock[name]["depends"])
    for name in sorted(needed):
        info = lock[name]
        data = fetch(PYODIDE_CDN + info["file_name"], cache, info["sha256"])
        (pyodide_dir / info["file_name"]).write_bytes(data)
    return sorted(needed)


def bundle_wheels(requirements, out, cache):
    wheel_dir = out / "wheels"
    wheel_dir.mkdir(parents=True)
    urls = []
    for requirement in requirements:
        name, version = requirement.split("==")
        with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{version}/json", timeout=60) as response:
            release = json.load(response)
        wheel = next(
            f for f in release["urls"]
            if f["packagetype"] == "bdist_wheel" and f["filename"].endswith("-none-any.whl")
        )
        data = fetch(wheel["url"], cache, wheel["digests"]["sha256"])
        (wheel_dir / wheel["filename"]).write_bytes(data)
        urls.append(APP_ORIGIN + "wheels/" + wheel["filename"])
    return urls


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Expected exactly one occurrence of: {old[:60]!r}")
    return text.replace(old, new)


NATIVE_HELPERS = """
      // Bridge to the macOS app: clipboard, save dialog and files opened from Finder or the menu.
      const native = (message) => window.webkit.messageHandlers.native.postMessage(message);
      let markReady;
      const converterReady = new Promise((resolve) => (markReady = resolve));
      function fileFromBase64(name, base64) {
        const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
        return new File([bytes], name);
      }
      window.nativeOpen = async (items) => {
        await converterReady;
        convert(items.map(({ name, data }) => fileFromBase64(name, data)));
      };
      window.nativeConvert = async (name, data) => {
        await converterReady;
        const bytes = await fileFromBase64(name, data).arrayBuffer();
        const id = nextId++;
        return new Promise((resolve, reject) => {
          pending.set(id, { done: resolve, fail: (error) => reject(new Error(error)) });
          worker.postMessage({ id, name, mimetype: "", bytes }, [bytes]);
        });
      };
"""


def desktop_page(page, wheel_urls):
    # The app shares the page's version number (build.sh copies it into Info.plist).
    page = replace_once(
        page,
        'MarkItDown Web <span id="app-version">',
        'MarkItDown for Mac <span id="app-version">',
    )
    wheels_literal = "WHEELS = [\n" + "".join(f'    "{url}",\n' for url in wheel_urls) + "]"
    page = re.sub(r"WHEELS = \[.*?\]", lambda _: wheels_literal, page, count=1, flags=re.S)
    # micropip only downloads from http(s); Pyodide's loader also accepts the app's own scheme.
    page = replace_once(
        page,
        "    await micropip.install(WHEELS, deps=False)\n",
        "    import pyodide_js\n    from pyodide.ffi import to_js\n\n"
        "    await pyodide_js.loadPackage(to_js(WHEELS))\n",
    )
    page = replace_once(page, "    import micropip\n\n", "")
    page = replace_once(page, '    "micropip", "lxml",', '    "lxml",')

    page = replace_once(
        page,
        f'const PYODIDE_URL = "{PYODIDE_CDN}";',
        f'const PYODIDE_URL = "{APP_ORIGIN}pyodide/";',
    )
    page = replace_once(page, "      const pending = new Map();\n      let nextId = 0;\n",
                        "      const pending = new Map();\n      let nextId = 0;\n" + NATIVE_HELPERS)
    page = replace_once(page, "input.disabled = false;\n        } else if",
                        "input.disabled = false;\n          markReady();\n        } else if")
    page = replace_once(page, "copy.onclick = () => navigator.clipboard.writeText(markdown);",
                        'copy.onclick = () => native({ action: "copy", text: markdown });')
    page = re.sub(
        r"download\.onclick = \(\) => \{.*?\n            \};",
        lambda _: (
            "download.onclick = () => {\n"
            '              const name = file.name.replace(/\\.[^.]*$/, "") + ".md";\n'
            '              native({ action: "save", name, text: markdown });\n'
            "            };"
        ),
        page, count=1, flags=re.S,
    )

    page = replace_once(page, "<title>MarkItDown (in your browser)</title>", "<title>MarkItDown</title>")
    page = replace_once(page, "Everything happens right here in your browser.", "Everything happens right here on your Mac.")
    page = replace_once(page, "Loading the converter. The first visit downloads about 35 MB.", "Loading the converter…")
    page = replace_once(
        page,
        "The converter downloads its runtime and packages when it starts.",
        "Everything the converter needs is bundled in the app. It never connects to the network.",
    )
    page = re.sub(r"<!--\n  MarkItDown in the browser.*?-->\n",
                  "<!-- Generated by desktop-macos/tools/prepare_web.py from browser-poc/index.html. Do not edit. -->\n",
                  page, count=1, flags=re.S)

    def digest(text):
        return "'sha256-" + base64.b64encode(hashlib.sha256(text.encode()).digest()).decode() + "'"

    script = re.search(r"<script>(.*?)</script>", page, re.S).group(1)
    style = re.search(r"<style>(.*?)</style>", page, re.S).group(1)
    csp = (
        f"default-src 'none'; script-src {digest(script)} {APP_ORIGIN}pyodide/ 'wasm-unsafe-eval'; "
        f"worker-src blob:; connect-src {APP_ORIGIN}; style-src {digest(style)}; img-src data:; "
        "base-uri 'none'; form-action 'none'"
    )
    return re.sub(r'(http-equiv="Content-Security-Policy"\s+content=")[^"]*"',
                  lambda m: m.group(1) + csp + '"', page, count=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()

    page = SOURCE_PAGE.read_text(encoding="utf-8")
    packages, requirements = python_lists(page)
    packages = [p for p in packages if p != "micropip"]
    shutil.rmtree(args.out, ignore_errors=True)
    args.out.mkdir(parents=True)
    args.cache.mkdir(parents=True, exist_ok=True)

    bundled = bundle_pyodide(packages, args.out, args.cache)
    wheel_urls = bundle_wheels(requirements, args.out, args.cache)
    (args.out / "index.html").write_text(desktop_page(page, wheel_urls), encoding="utf-8")
    shutil.copy(SOURCE_PAGE.parent / "LICENSE", args.out / "LICENSE")
    print(f"Bundled {len(bundled)} Pyodide packages and {len(wheel_urls)} wheels into {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
