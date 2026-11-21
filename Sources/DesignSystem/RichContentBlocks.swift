// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

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
        case .math, .inlineMath: return loc.t("Fórmula", "Formula")
        case .mermaid: return "Mermaid"
        case .svg: return "SVG"
        }
    }

    private var icon: String {
        switch kind {
        case .math, .inlineMath: return "function"
        case .mermaid: return "point.3.connected.trianglepath.dotted"
        case .svg: return "scribble.variable"
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
                Button(loc.t("Cerrar", "Close"), systemImage: "xmark", action: { dismiss() })
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            RichWebView(source: source, kind: kind, contentHeight: $height, zoom: zoom,
                        scrollsInternally: true)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct InlineMathText: View {
    let source: String
    var base: ChatFont.Base = .body
    var bold = false
    @State private var height: CGFloat = 24
    @State private var baseline: CGFloat = 0
    @Environment(\.chatFontScale) private var scale

    var body: some View {
        RichWebView(source: source, kind: .inlineMath, contentHeight: $height,
                    fontSize: base.points * scale, bold: bold, firstBaseline: $baseline)
            .frame(height: min(max(height, 16), 360))
            // Lines up with a list marker beside it.
            .alignmentGuide(.firstTextBaseline) { d in baseline > 0 ? baseline : d[.firstTextBaseline] }
            .accessibilityLabel(Text(source))
    }
}

/// Embedded in the transcript the page must not take the wheel: its own scroll
/// area would swallow the gesture.
final class RichContentWebView: WKWebView {
    var forwardsVerticalScroll = false

    override func scrollWheel(with event: NSEvent) {
        guard forwardsVerticalScroll,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
              let next = nextResponder else {
            super.scrollWheel(with: event)
            return
        }
        next.scrollWheel(with: event)
    }
}

struct RichWebView: NSViewRepresentable {
    let source: String
    let kind: RichContentKind
    @Binding var contentHeight: CGFloat
    var zoom: CGFloat = 1
    /// Only the expanded preview keeps its own scrolling.
    var scrollsInternally = false
    var fontSize: CGFloat = 14
    var bold = false
    var firstBaseline: Binding<CGFloat>?

    func makeCoordinator() -> Coordinator { Coordinator(height: $contentHeight, baseline: firstBaseline) }

    func makeNSView(context: Context) -> RichContentWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "height")
        let view = RichContentWebView(frame: .zero, configuration: configuration)
        view.forwardsVerticalScroll = !scrollsInternally
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        view.setMagnification(zoom, centeredAt: .zero)
        context.coordinator.signature = signature
        view.loadHTMLString(Self.html(source: source, kind: kind, fontSize: fontSize, bold: bold),
                            baseURL: Self.assetsDirectory)
        return view
    }

    static func dismantleNSView(_ view: RichContentWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    func updateNSView(_ view: RichContentWebView, context: Context) {
        view.forwardsVerticalScroll = !scrollsInternally
        context.coordinator.height = $contentHeight
        context.coordinator.baseline = firstBaseline
        if abs(view.magnification - zoom) > 0.001 {
            view.setMagnification(zoom, centeredAt: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        }
        guard context.coordinator.signature != signature else { return }
        context.coordinator.signature = signature
        view.loadHTMLString(Self.html(source: source, kind: kind, fontSize: fontSize, bold: bold),
                            baseURL: Self.assetsDirectory)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var baseline: Binding<CGFloat>?
        var signature = ""

        init(height: Binding<CGFloat>, baseline: Binding<CGFloat>? = nil) {
            self.height = height
            self.baseline = baseline
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let report = message.body as? [String: Any],
                  let value = report["height"] as? NSNumber else { return }
            update(height, to: CGFloat(truncating: value))
            if let baseline, let value = report["baseline"] as? NSNumber {
                update(baseline, to: CGFloat(truncating: value))
            }
        }

        private func update(_ binding: Binding<CGFloat>, to value: CGFloat) {
            if abs(binding.wrappedValue - value) >= 0.5 { binding.wrappedValue = value }
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

    private var signature: String {
        "\(String(describing: kind)):\(fontSize):\(bold):\(source.hashValue)"
    }

    static func html(source: String, kind: RichContentKind, fontSize: CGFloat = 14, bold: Bool = false) -> String {
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
            \#(RichText.inlineMathScript)
            const { text: tokenized, formulas } = toshTokenizeMath(\#(encoded));
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
            const probe = document.createElement('span'); probe.id = 'toshBaseline';
            document.getElementById('content').prepend(probe);
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
        body { padding:\(bodyPadding); font:\(bold ? "bold " : "")\(fontSize)px -apple-system, BlinkMacSystemFont, sans-serif; color:CanvasText; }
        #content { display:flow-root; min-width:\(minimumWidth); transform-origin:top left; overflow-wrap:anywhere; }
        #content p { margin:0; } .inline-math { white-space:nowrap; }
        #toshBaseline { display:inline-block; width:0; height:0; }
        svg, .svg-content { display:block; max-width:none; height:auto; }
        </style></head><body><div id="content"></div>
        <script>\(heightScript)</script>
        \(payload)<script>report(); new ResizeObserver(report).observe(document.getElementById('content')); document.fonts.ready.then(report);</script>
        </body></html>
        """
    }
}

extension RichWebView {
    /// Measures the content itself: the document's scroll height never drops
    /// below the frame, so a report based on it could only grow.
    static let heightScript = """
    let toshPending = false, toshLast = '';
    function toshMeasure() {
      const content = document.getElementById('content');
      const body = getComputedStyle(document.body);
      const scrollbar = Math.max(0, window.innerHeight - document.documentElement.clientHeight);
      return Math.ceil(content.getBoundingClientRect().height
        + parseFloat(body.paddingTop) + parseFloat(body.paddingBottom) + scrollbar);
    }
    function report() {
      if (toshPending) return;
      toshPending = true;
      requestAnimationFrame(() => {
        toshPending = false;
        const probe = document.getElementById('toshBaseline');
        const baseline = probe ? Math.round(probe.getBoundingClientRect().bottom + window.scrollY) : 0;
        const sizes = { height: toshMeasure(), baseline };
        const key = sizes.height + ':' + baseline;
        if (key !== toshLast) { toshLast = key; webkit.messageHandlers.height.postMessage(sizes); }
      });
    }
    """
}

enum RichContentIsolation {
    static func svgDataURL(_ value: String) -> String {
        "data:image/svg+xml;base64," + Data(value.utf8).base64EncodedString()
    }
}
