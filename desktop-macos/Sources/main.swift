import AppKit
import UniformTypeIdentifiers
import WebKit

// Serves the bundled web files at markitdown://app/ so the page, Pyodide and the
// wheels load from inside the app. Nothing is fetched from the network.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "markitdown"
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "app" else {
            return task.didFailWithError(URLError(.unsupportedURL))
        }
        let relative = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            task.didReceive(response)
            task.didReceive(Data())
            return task.didFinish()
        }
        let headers = [
            "Content-Type": Self.mimeType(for: file),
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        case "zip", "whl": return "application/zip"
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var pendingFiles: [URL] = []
    private var pageLoaded = false
    private let selfTestFiles: [URL]? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--self-test") else { return nil }
        return args[(index + 1)...].map { URL(fileURLWithPath: $0) }
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let webRoot = Bundle.main.resourceURL!.appendingPathComponent("web")

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(root: webRoot), forURLScheme: BundleSchemeHandler.scheme)
        config.userContentController.add(self, name: "native")
        config.websiteDataStore = .nonPersistent()

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "MarkItDown"
        window.minSize = NSSize(width: 420, height: 480)
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("MarkItDownMainWindow")
        window.isReleasedWhenClosed = false
        if selfTestFiles == nil {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Second line of defence after the page's CSP: block every http(s)/ws(s) load.
        let rules = ["^https?://", "^wss?://", "^ftp://"]
            .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
            .joined(separator: ",")
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "block-network", encodedContentRuleList: "[\(rules)]") { list, error in
            guard let list else {
                fatalError("Could not compile the network block list: \(String(describing: error))")
            }
            config.userContentController.add(list)
            self.webView.load(URLRequest(url: URL(string: "\(BundleSchemeHandler.scheme)://app/index.html")!))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingFiles += urls
        flushPendingFiles()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MarkItDown", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MarkItDown", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit MarkItDown", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        for submenu in [appMenu, fileMenu, editMenu, viewMenu, windowMenu] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        NSApp.mainMenu = main
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            self.application(NSApp, open: panel.urls)
        }
    }

    // MARK: Passing files to the page

    private func flushPendingFiles() {
        guard pageLoaded, !pendingFiles.isEmpty else { return }
        let items: [[String: String]] = pendingFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ["name": url.lastPathComponent, "data": data.base64EncodedString()]
        }
        pendingFiles.removeAll()
        webView.callAsyncJavaScript("await nativeOpen(items)", arguments: ["items": items], in: nil, in: .page) { _ in }
        window.makeKeyAndOrderFront(nil)
    }

    private func runSelfTest(_ files: [URL]) {
        Task { @MainActor in
            // Wait for the converter to start, reporting a start-up failure instead of hanging.
            var started = false
            for _ in 0..<240 {
                let state = try? await webView.callAsyncJavaScript(
                    #"const s = document.getElementById("status"); return [s.dataset.state || "", s.textContent]"#,
                    arguments: [:], in: nil, contentWorld: .page) as? [String]
                if state?.first == "ready" { started = true; break }
                if state?.first == "error" {
                    print("Converter failed to start: \(state?.last ?? "")")
                    exit(2)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if !started {
                print("Converter did not start within 120 seconds")
                exit(3)
            }
            var failed = false
            let network = try? await webView.callAsyncJavaScript(
                #"try { await fetch("https://example.com/", { mode: "no-cors" }); return "reachable" } catch { return "blocked" }"#,
                arguments: [:], in: nil, contentWorld: .page) as? String
            print("=== network: \(network ?? "unknown")")
            if network != "blocked" { failed = true }
            for url in files {
                do {
                    let data = try Data(contentsOf: url)
                    let markdown = try await webView.callAsyncJavaScript(
                        "return await nativeConvert(name, data)",
                        arguments: ["name": url.lastPathComponent, "data": data.base64EncodedString()],
                        in: nil, contentWorld: .page)
                    print("=== \(url.lastPathComponent)\n\(markdown as? String ?? "")")
                } catch {
                    failed = true
                    print("=== \(url.lastPathComponent) FAILED: \(error)")
                }
            }
            exit(failed ? 1 : 0)
        }
    }

    // MARK: WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        flushPendingFiles()
        if let files = selfTestFiles { runSelfTest(files) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == BundleSchemeHandler.scheme || url.scheme == "about" || url.scheme == "blob" {
            return decisionHandler(.allow)
        }
        // External links (the original project, the license page) open in the default browser.
        if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["https", "http"].contains(url.scheme) { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLoaded = false
        webView.reload()
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == BundleSchemeHandler.scheme,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let text = body["text"] as? String else { return }
        switch action {
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "save":
            let panel = NSSavePanel()
            panel.nameFieldStringValue = body["name"] as? String ?? "document.md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: self.window)
                }
            }
        default:
            break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
