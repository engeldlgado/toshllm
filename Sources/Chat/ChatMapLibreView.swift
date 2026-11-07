// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import WebKit

/// The base map of the chat's maps, in the app and in the web chat: PMTiles regions in a folder, drawn without
/// internet, a MapLibre style of the person's choice, or OpenFreeMap online.
enum MapBase {
    static var style: String {
        (UserDefaults.standard.string(forKey: SettingsKeys.mapStyle) ?? "").trimmingCharacters(in: .whitespaces)
    }

    static var folder: URL? {
        guard let value = UserDefaults.standard.string(forKey: SettingsKeys.mapFolder), !value.isEmpty else { return nil }
        let path = (value as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The region files in the folder, by name.
    static var regions: [String] {
        guard let folder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.lowercased().hasSuffix(".pmtiles") }.sorted()
    }

    /// Whether the folder holds the fonts and icons for the regions' labels, in assets/ as Protomaps publishes them.
    static var labels: Bool {
        guard let fonts = file("assets/fonts") else { return false }
        return FileManager.default.fileExists(atPath: fonts.path)
    }

    /// A file inside the folder; nil for a path that would leave it.
    static func file(_ relative: String) -> URL? {
        guard let folder else { return nil }
        let url = folder.appendingPathComponent(relative).standardizedFileURL
        return url.path.hasPrefix(folder.standardizedFileURL.path + "/") ? url : nil
    }
}

/// Serves the map page from the app and the map folder under tiles/, in byte ranges, as the server does for the web
/// chat. MapLibre's worker does not start on a file:// page.
final class MapPageScheme: NSObject, WKURLSchemeHandler {
    static let name = "toshmap"
    static let page = URL(string: "toshmap://app/map.html")!
    private static let pageFiles: Set<String> = ["map.html", "toshmap.js", "maplibre-gl.css"]
    private var running = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = String(url.path.drop { $0 == "/" })
        let file = path.hasPrefix("tiles/")
            ? MapBase.file(String(path.dropFirst("tiles/".count)))
            : Self.pageFiles.contains(path)
                ? Bundle.main.resourceURL?.appendingPathComponent("rich-content/maplibre/\(path)") : nil
        let range = task.request.value(forHTTPHeaderField: "Range")
        let id = ObjectIdentifier(task)
        running.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = Self.reply(file, range: range)
            DispatchQueue.main.async { [weak self] in
                // a task WebKit has stopped must not be answered
                guard let self, self.running.remove(id) != nil,
                      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                                     headerFields: reply.headers) else { return }
                task.didReceive(response)
                task.didReceive(reply.data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    static func reply(_ file: URL?, range: String?) -> (status: Int, headers: [String: String], data: Data) {
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return (404, [:], Data()) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start: UInt64 = 0, end: UInt64 = size > 0 ? size - 1 : 0, status = 200
        if let range, range.hasPrefix("bytes="), size > 0 {
            let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            start = min(UInt64(bounds.first ?? "") ?? 0, size - 1)
            if bounds.count > 1, let last = UInt64(bounds[1]) { end = min(last, end) }
            status = 206
        }
        var data = Data()
        if size > 0, end >= start, (try? handle.seek(toOffset: start)) != nil {
            data = (try? handle.read(upToCount: Int(end - start + 1))) ?? Data()
        }
        var headers = ["Content-Type": contentType(file), "Content-Length": "\(data.count)", "Accept-Ranges": "bytes"]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(start + UInt64(max(data.count, 1)) - 1)/\(size)" }
        return (status, headers, data)
    }

    private static func contentType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "pbf": return "application/x-protobuf"
        default: return "application/octet-stream"
        }
    }
}

/// A map of the layers on MapLibre, for every map that holds no Apple Maps data. A click on a feature reports its
/// attributes, as on the Apple map.
struct ChatMapLibreCanvas: NSViewRepresentable {
    let map: ChatMap
    let onSelect: (ChatMapFeature?) -> Void

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RichContentWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.scheme, forURLScheme: MapPageScheme.name)
        configuration.userContentController.add(context.coordinator, name: "select")
        let view = RichContentWebView(frame: .zero, configuration: configuration)
        // the chat scrolls past the map; the map zooms with its buttons
        view.forwardsVerticalScroll = true
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.onSelect = onSelect
        load(view, context.coordinator)
        return view
    }

    static func dismantleNSView(_ view: RichContentWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "select")
    }

    func updateNSView(_ view: RichContentWebView, context: Context) {
        context.coordinator.onSelect = onSelect
        guard context.coordinator.drawn != signature else { return }
        load(view, context.coordinator)
    }

    private var dark: Bool { colorScheme == .dark }

    private var signature: String {
        "\(map.layers.count)-\(map.layers.map(\.geojson.count))-\(dark)-\(MapBase.style)-\(MapBase.regions)-\(MapBase.labels)"
    }

    private func load(_ view: RichContentWebView, _ coordinator: Coordinator) {
        coordinator.drawn = signature
        coordinator.map = map
        let layers: [[String: Any]] = map.layers.enumerated().map { index, layer in
            let object = (try? JSONSerialization.jsonObject(with: layer.geojson)) as? [String: Any]
            return ["features": object?["features"] ?? [], "drawn": layer.drawn == true,
                    "color": Self.hex(ChatMapCanvas.color(index))]
        }
        let config: [String: Any] = ["layers": layers, "style": MapBase.style, "regions": MapBase.regions,
                                     "labels": MapBase.labels, "dark": dark,
                                     "lang": (Locale.current.languageCode ?? "en")]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return }
        let scripts = view.configuration.userContentController
        scripts.removeAllUserScripts()
        scripts.addUserScript(WKUserScript(source: "window.TOSH_MAP_CONFIG = \(String(decoding: data, as: UTF8.self));",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view.load(URLRequest(url: MapPageScheme.page))
    }

    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let scheme = MapPageScheme()
        var onSelect: (ChatMapFeature?) -> Void = { _ in }
        var drawn = ""
        var map: ChatMap?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let index = body["layer"] as? Int,
                  let map, map.layers.indices.contains(index) else { return }
            let properties = body["properties"] as? [String: Any] ?? [:]
            onSelect(ChatMapCanvas.feature(properties, layer: map.layers[index], index: index))
        }

        // the map's credits link to their sites, which open in the browser
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme != MapPageScheme.name else { return decisionHandler(.allow) }
            if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}
