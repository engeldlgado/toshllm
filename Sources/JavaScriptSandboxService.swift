import Foundation
import WebKit

enum JavaScriptSandboxService {
    static let toolName = "run_javascript"
    static let defaultTimeoutMS = 10_000
    static let maximumTimeoutMS = 30_000
    static let maximumOutputCharacters = 8_192

    static let tool: BuiltinToolInfo = try! BuiltinToolInfo(
        displayName: "JavaScript sandbox",
        name: toolName,
        writesData: false,
        definition: [
            "type": "function",
            "function": [
                "name": toolName,
                "description": "Execute JavaScript in a sandboxed browser worker (no DOM, no page access). Top level await is supported. Use console.log to print intermediate values; a top level return statement is captured as the result.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "code": ["type": "string", "description": "JavaScript source to execute"],
                        "timeout_ms": [
                            "type": "number",
                            "description": "Execution timeout in milliseconds, default 10000, max 30000"
                        ]
                    ],
                    "required": ["code"]
                ]
            ]
        ])

    @MainActor
    static func execute(arguments: [String: Any]) async -> ToolExecutionResult {
        guard let code = arguments["code"] as? String, !code.isEmpty else {
            return ToolExecutionResult(content: "Missing required parameter: code", isError: true)
        }
        let requested = (arguments["timeout_ms"] as? NSNumber)?.doubleValue
        let timeout = requested.map { value in
            value.isFinite && value > 0 ? min(Int(value), maximumTimeoutMS) : defaultTimeoutMS
        } ?? defaultTimeoutMS
        let session = JavaScriptSandboxSession()
        return await withTaskCancellationHandler {
            await session.run(code: code, timeoutMS: timeout)
        } onCancel: {
            Task { @MainActor in session.cancel() }
        }
    }

    static func formatReply(logs: [String], result: String?, error: String?) -> ToolExecutionResult {
        var lines = logs
        if let error { lines.append("Error: \(error)") }
        else if let result { lines.append("=> \(result)") }
        var content = lines.joined(separator: "\n")
        if content.isEmpty { content = "(no output)" }
        if content.count > maximumOutputCharacters {
            content = String(content.prefix(maximumOutputCharacters)) + "\n[output truncated]"
        }
        return ToolExecutionResult(content: content, isError: error != nil)
    }
}

@MainActor
private final class JavaScriptSandboxSession: NSObject, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<ToolExecutionResult, Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(code: String, timeoutMS: Int) async -> ToolExecutionResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let controller = WKUserContentController()
            controller.add(self, name: "sandboxReply")
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController = controller
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

            let webView = WKWebView(frame: .zero, configuration: configuration)
            self.webView = webView
            webView.loadHTMLString(Self.harness(code: code), baseURL: nil)

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMS))
                guard !Task.isCancelled else { return }
                self?.finish(ToolExecutionResult(
                    content: "Execution timed out after \(timeoutMS) ms", isError: true))
            }
        }
    }

    func cancel() {
        finish(ToolExecutionResult(content: "Sandbox execution aborted", isError: true))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else {
            finish(ToolExecutionResult(content: "Invalid sandbox response", isError: true))
            return
        }
        let logs = (body["logs"] as? [Any])?.map(String.init(describing:)) ?? []
        let result = body["result"].flatMap(Self.optionalString)
        let error = body["error"].flatMap(Self.optionalString)
        finish(JavaScriptSandboxService.formatReply(logs: logs, result: result, error: error))
    }

    private static func optionalString(_ value: Any) -> String? {
        value is NSNull ? nil : String(describing: value)
    }

    private func finish(_ result: ToolExecutionResult) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "sandboxReply")
        webView?.stopLoading()
        webView = nil
        continuation.resume(returning: result)
    }

    private static func harness(code: String) -> String {
        let codeData = try! JSONSerialization.data(withJSONObject: [code])
        let codeArray = String(decoding: codeData, as: UTF8.self)
        return """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' blob:; worker-src blob:; connect-src 'none'; img-src 'none'; media-src 'none'; frame-src 'none'">
        </head><body><script>
        const code = \(codeArray)[0];
        const workerSource = `
        const logs = [];
        const fmt = value => {
          if (typeof value === 'string') return value;
          try { return JSON.stringify(value); } catch (_) { return String(value); }
        };
        const capture = prefix => (...args) => logs.push(prefix + args.map(fmt).join(' '));
        console.log = capture(''); console.info = capture(''); console.debug = capture('');
        console.warn = capture('warn: '); console.error = capture('error: ');
        self.fetch = () => Promise.reject(new Error('Network access is disabled'));
        self.XMLHttpRequest = undefined; self.WebSocket = undefined; self.EventSource = undefined;
        self.importScripts = () => { throw new Error('External scripts are disabled'); };
        self.onmessage = async event => {
          const reply = { logs, result: null, error: null };
          try {
            const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
            const value = await new AsyncFunction(event.data.code)();
            if (value !== undefined) reply.result = fmt(value);
          } catch (error) {
            reply.error = error instanceof Error ? (error.stack || error.message) : String(error);
          }
          self.postMessage(reply);
        };`;
        try {
          const blobURL = URL.createObjectURL(new Blob([workerSource], {type: 'text/javascript'}));
          const worker = new Worker(blobURL);
          worker.onmessage = event => window.webkit.messageHandlers.sandboxReply.postMessage(event.data);
          worker.onerror = error => window.webkit.messageHandlers.sandboxReply.postMessage({logs: [], result: null, error: String(error.message || error)});
          worker.postMessage({code});
        } catch (error) {
          window.webkit.messageHandlers.sandboxReply.postMessage({logs: [], result: null, error: 'Worker creation failed: ' + error});
        }
        </script></body></html>
        """
    }
}
