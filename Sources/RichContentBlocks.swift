import SwiftUI
import WebKit

enum RichContentKind {
    case math
    case inlineMath
    case mermaid
    case svg
}

struct RichContentBlock: View {
    let source: String
    let kind: RichContentKind
    @State private var height: CGFloat = 140
    @State private var previewing = false
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(loc.t("Ampliar", "Expand"), systemImage: "arrow.up.left.and.arrow.down.right") {
                    previewing = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(loc.t("Abrir vista interactiva", "Open interactive preview"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.3))

            RichWebView(source: source, kind: kind, contentHeight: $height)
                .frame(height: min(max(height, 80), 520))
        }
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $previewing) {
            RichContentPreview(source: source, kind: kind, title: label)
                .environmentObject(loc)
        }
    }

    private var label: String {
        switch kind {
        case .math, .inlineMath: loc.t("Fórmula", "Formula")
        case .mermaid: "Mermaid"
        case .svg: "SVG"
        }
    }

    private var icon: String {
        switch kind {
        case .math, .inlineMath: "function"
        case .mermaid: "point.3.connected.trianglepath.dotted"
        case .svg: "scribble.variable"
        }
    }
}

private struct RichContentPreview: View {
    let source: String
    let kind: RichContentKind
    let title: String
    @State private var height: CGFloat = 600
    @State private var zoom: CGFloat = 1
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(loc.t("Reducir", "Zoom out"), systemImage: "minus.magnifyingglass") {
                    zoom = max(0.5, zoom - 0.15)
                }
                .labelStyle(.iconOnly)
                .disabled(zoom <= 0.5)
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 44)
                Button(loc.t("Tamaño real", "Actual size"), systemImage: "1.magnifyingglass") {
                    zoom = 1
                }
                .labelStyle(.iconOnly)
                Button(loc.t("Ampliar", "Zoom in"), systemImage: "plus.magnifyingglass") {
                    zoom = min(3, zoom + 0.15)
                }
                .labelStyle(.iconOnly)
                .disabled(zoom >= 3)
                Button(loc.t("Cerrar", "Close"), systemImage: "xmark", action: dismiss.callAsFunction)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            RichWebView(source: source, kind: kind, contentHeight: $height, zoom: zoom)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct InlineMathText: View {
    let source: String
    @State private var height: CGFloat = 24

    var body: some View {
        RichWebView(source: source, kind: .inlineMath, contentHeight: $height)
            .frame(height: min(max(height, 20), 360))
            .accessibilityLabel(Text(source))
    }
}

struct RichWebView: NSViewRepresentable {
    let source: String
    let kind: RichContentKind
    @Binding var contentHeight: CGFloat
    var zoom: CGFloat = 1

    func makeCoordinator() -> Coordinator { Coordinator(height: $contentHeight) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "height")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        view.setMagnification(zoom, centeredAt: .zero)
        context.coordinator.signature = Self.signature(source: source, kind: kind)
        view.loadHTMLString(Self.html(source: source, kind: kind), baseURL: Self.assetsDirectory)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.height = $contentHeight
        if abs(view.magnification - zoom) > 0.001 {
            view.setMagnification(zoom, centeredAt: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        }
        let signature = Self.signature(source: source, kind: kind)
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        view.loadHTMLString(Self.html(source: source, kind: kind), baseURL: Self.assetsDirectory)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var signature = ""

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let value = message.body as? NSNumber else { return }
            height.wrappedValue = CGFloat(truncating: value) + 20
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" || scheme == "mailto" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    private static var assetsDirectory: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("rich-content"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("vendor/llama.cpp/tools/ui/node_modules")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    private static func signature(source: String, kind: RichContentKind) -> String {
        "\(String(describing: kind)):\(source.hashValue)"
    }

    private static func html(source: String, kind: RichContentKind) -> String {
        let encoded = (try? String(data: JSONEncoder().encode(source), encoding: .utf8)) ?? "\"\""
        let payload: String
        switch kind {
        case .math:
            payload = """
            <link rel="stylesheet" href="katex/dist/katex.min.css">
            <script src="katex/dist/katex.min.js"></script>
            <script>katex.render(\(encoded), document.getElementById('content'), {displayMode:true, throwOnError:false});</script>
            """
        case .inlineMath:
            payload = #"""
            <link rel="stylesheet" href="katex/dist/katex.min.css">
            <script src="katex/dist/katex.min.js"></script>
            <script src="marked/lib/marked.umd.js"></script>
            <script>
            const raw = \#(encoded);
            const formulas = [];
            const tokenized = raw.replace(/\\\((.+?)\\\)|(?<![\\$])\$(?!\$)(.+?)(?<![\\$])\$(?!\$)/gs, (_, paren, dollar) => {
              const token = `TOSHMATH${formulas.length}TOKEN`;
              formulas.push(paren ?? dollar);
              return token;
            });
            const escaped = tokenized.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
            document.getElementById('content').innerHTML = marked.parseInline(escaped, {gfm:true, breaks:true});
            const walker = document.createTreeWalker(document.getElementById('content'), NodeFilter.SHOW_TEXT);
            const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
            for (const node of nodes) {
              const pieces = node.nodeValue.split(/(TOSHMATH\d+TOKEN)/g);
              if (pieces.length === 1) continue;
              const fragment = document.createDocumentFragment();
              for (const piece of pieces) {
                const match = /^TOSHMATH(\d+)TOKEN$/.exec(piece);
                if (!match) { fragment.append(document.createTextNode(piece)); continue; }
                const span = document.createElement('span'); span.className = 'inline-math';
                katex.render(formulas[Number(match[1])], span, {displayMode:false, throwOnError:false});
                fragment.append(span);
              }
              node.replaceWith(fragment);
            }
            for (const anchor of document.querySelectorAll('a[href]')) {
              const protocol = new URL(anchor.href).protocol;
              if (!['http:', 'https:', 'mailto:'].includes(protocol)) anchor.removeAttribute('href');
            }
            </script>
            """#
        case .mermaid:
            payload = """
            <script src="mermaid/dist/mermaid.min.js"></script>
            <script>
            mermaid.initialize({startOnLoad:false, theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default', securityLevel:'strict'});
            mermaid.render('diagram', \(encoded)).then(({svg}) => { document.getElementById('content').innerHTML = svg; report(); });
            </script>
            """
        case .svg:
            // An SVG image document cannot execute active markup in the host page.
            let imageURL = RichContentIsolation.svgDataURL(source)
            let imageEncoded = (try? String(data: JSONEncoder().encode(imageURL), encoding: .utf8)) ?? "\"\""
            payload = """
            <script>
            const image = document.createElement('img');
            image.className = 'svg-content'; image.alt = 'SVG'; image.src = \(imageEncoded);
            image.addEventListener('load', report); image.addEventListener('error', report);
            document.getElementById('content').append(image);
            </script>
            """
        }
        let inline: Bool
        switch kind {
        case .inlineMath: inline = true
        default: inline = false
        }
        let bodyPadding = inline ? "0" : "12px"
        let minimumWidth = inline ? "0" : "max-content"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src data: blob:; connect-src 'none'; media-src 'none'; frame-src 'none'">
        <style>
        :root { color-scheme: light dark; } html,body { margin:0; background:transparent; overflow:auto; }
        body { padding:\(bodyPadding); font:14px -apple-system, BlinkMacSystemFont, sans-serif; color:CanvasText; }
        #content { min-width:\(minimumWidth); transform-origin:top left; overflow-wrap:anywhere; }
        #content p { margin:0; } .inline-math { white-space:nowrap; }
        svg, .svg-content { display:block; max-width:none; height:auto; }
        </style></head><body><div id="content"></div>
        <script>function report(){requestAnimationFrame(()=>webkit.messageHandlers.height.postMessage(document.documentElement.scrollHeight));}</script>
        \(payload)<script>report(); new ResizeObserver(report).observe(document.getElementById('content'));</script>
        </body></html>
        """
    }
}

enum RichContentIsolation {
    static func svgDataURL(_ value: String) -> String {
        "data:image/svg+xml;base64," + Data(value.utf8).base64EncodedString()
    }
}
