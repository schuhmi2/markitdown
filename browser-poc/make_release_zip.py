"""Build the downloadable web release: dist/MarkItDown-Web-<version>.zip.

The zip holds one folder with index.html, LICENSE and a short README.txt. Users extract it and
double-click index.html; no server is needed.
"""

import re
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FOLDER = "MarkItDown-Web"

README = """MarkItDown Web {version}
Built on Microsoft's open-source MarkItDown {upstream}: https://github.com/microsoft/markitdown

How to use
1. Extract this zip anywhere on your computer (Windows, macOS or Linux).
2. Double-click index.html. It opens in your web browser (Chrome, Edge, Firefox or Safari).
3. Drop documents onto the page and copy or download the Markdown.

Your files are converted inside your browser and are never uploaded. The browser does download
the Python runtime and converter packages from the internet when the page starts, so an
internet connection is needed.

Source and other downloads: https://github.com/schuhmi2/markitdown
License: MIT (see LICENSE).
"""


def main():
    page = (HERE / "index.html").read_text(encoding="utf-8")
    version = re.search(r'<span id="app-version">([^<]+)<', page).group(1)
    upstream = re.search(r'"markitdown==([^"]+)"', page).group(1)
    files = {
        "index.html": page.encode("utf-8"),
        "LICENSE": (HERE / "LICENSE").read_bytes(),
        "README.txt": README.format(version=version, upstream=upstream).encode("utf-8"),
    }
    out = HERE / "dist" / f"MarkItDown-Web-{version}.zip"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in files.items():
            # Fixed timestamps and permissions make the zip reproducible.
            info = zipfile.ZipInfo(f"{FOLDER}/{name}", date_time=(2026, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, data)
    print(out)


if __name__ == "__main__":
    main()
