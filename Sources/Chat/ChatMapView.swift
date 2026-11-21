import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// Features an agent attached to an answer, drawn under it. The agent sends only a request with its answer;
/// the features come in a second call, so the answer is never delayed by them.
struct ChatMap: Codable, Equatable {
    struct Field: Codable, Equatable {
        var name: String
        var alias: String
    }

    struct Layer: Codable, Equatable {
        var title: String?
        /// A GeoJSON FeatureCollection in longitude/latitude.
        var geojson: Data
        var linkTitle: String?
        var linkURL: String?
        var complete: Bool
        /// Which features of the layer these are, such as its filter or "first 5 by POP2000 DESC".
        var subtitle: String? = nil
        /// The attributes in the layer's own order, with the names a GIS shows for them.
        var fields: [Field]? = nil
        var count: Int? = nil
        /// Drawn by the model from coordinates it gave, not read from data: shown dashed. Optional so that maps
        /// saved before it still load.
        var drawn: Bool? = nil
        /// Apple Maps data, which may only be shown on an Apple map.
        var apple: Bool? = nil

        var isApple: Bool { apple == true || subtitle?.contains("Apple Maps") == true }
    }

    var layers: [Layer]
}

extension ChatStore {
    /// Keeps the agent's map request on the answer, and fetches the map at once when the request asked for one.
    func attachMapRequest(_ request: [String: Any], conversation id: UUID, port: Int) {
        guard let i = conversations.firstIndex(where: { $0.id == id }),
              let j = conversations[i].messages.indices.last, conversations[i].messages[j].role == "assistant",
              let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        conversations[i].messages[j].mapRequest = String(decoding: data, as: UTF8.self)
        save()
        if request["show"] as? Bool == true {
            loadMap(for: conversations[i].messages[j].id, port: port)
        }
    }

    func loadMap(for messageID: UUID, port: Int) {
        guard !mapLoading.contains(messageID),
              let (i, j) = messagePosition(messageID),
              let raw = conversations[i].messages[j].mapRequest,
              let request = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else { return }
        mapLoading.insert(messageID)
        mapFailed.remove(messageID)
        let question = conversations[i].messages[..<j].last(where: { $0.role == "user" })?.content ?? ""
        Task { [weak self] in
            let map = await Self.fetchMap(request: request, question: question, port: port)
            await self?.applyMap(map, to: messageID)
        }
    }

    /// A method rather than the write inline in a MainActor.run closure: Swift 5.7
    /// refuses a deep mutation of an isolated property through that closure.
    private func applyMap(_ map: ChatMap?, to messageID: UUID) {
        mapLoading.remove(messageID)
        guard let map, let (i, j) = messagePosition(messageID) else {
            mapFailed.insert(messageID)
            return
        }
        conversations[i].messages[j].map = map
        save()
    }

    private func messagePosition(_ id: UUID) -> (Int, Int)? {
        for (i, conversation) in conversations.enumerated() {
            if let j = conversation.messages.firstIndex(where: { $0.id == id }) { return (i, j) }
        }
        return nil
    }

    private static func fetchMap(request: Any, question: String, port: Int) async -> ChatMap? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("on", forHTTPHeaderField: "X-Tosh-Agent")
        req.timeoutInterval = 120
        if let key = ServerSettings.activeAPIKey() {
            req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["messages": [["role": "user", "content": question]], "stream": false,
                                   "tosh": ["map_request": request]]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = payload
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = ((object["tosh"] as? [String: Any])?["map"] as? [String: Any])?["layers"] as? [[String: Any]]
        else { return nil }
        let drawn = layers.compactMap { layer -> ChatMap.Layer? in
            let link = layer["link"] as? [String: Any]
            let features = layer.filter { ["type", "features"].contains($0.key) }
            guard let geojson = try? JSONSerialization.data(withJSONObject: features) else { return nil }
            let fields = (layer["fields"] as? [[String: Any]])?.compactMap { field -> ChatMap.Field? in
                guard let name = field["name"] as? String else { return nil }
                return ChatMap.Field(name: name, alias: field["alias"] as? String ?? name)
            }
            return ChatMap.Layer(title: layer["title"] as? String, geojson: geojson,
                                 linkTitle: link?["title"] as? String, linkURL: link?["url"] as? String,
                                 complete: layer["complete"] as? Bool ?? true,
                                 subtitle: layer["subtitle"] as? String, fields: fields,
                                 count: (layer["features"] as? [Any])?.count)
        }
        return drawn.isEmpty ? nil : ChatMap(layers: drawn)
    }
}

/// One feature the person clicked: its layer and its attributes, ready to read.
struct ChatMapFeature: Identifiable, Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    let id = UUID()
    let layer: Int
    let title: String?
    let rows: [Row]
}

/// Under an answer that has something to draw: the map once fetched, or a button to fetch it.
struct ChatMapSection: View {
    let message: ChatMessage
    let loading: Bool
    let failed: Bool
    let onShow: () -> Void

    @EnvironmentObject var loc: Localizer
    @State private var selected: ChatMapFeature?
    @State private var enlarged = false

    var body: some View {
        if let map = message.map {
            VStack(alignment: .leading, spacing: 6) {
                canvas(map)
                    .frame(height: enlarged ? 460 : 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) {
                        if let selected {
                            ChatMapFeatureCard(feature: selected, onClose: { self.selected = nil })
                                .padding(10)
                        }
                    }
                legend(map)
                if map.layers.contains(where: { !$0.complete }) {
                    Text(loc.t("El mapa muestra parte de los resultados: no todos caben.",
                               "The map shows part of the results: not all of them fit."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else if message.mapRequest != nil {
            HStack(spacing: 8) {
                Button(action: onShow) {
                    Label(loc.t("Ver en el mapa", "Show on a map"), systemImage: "map")
                        .font(.callout)
                }
                .glassButton()
                .disabled(loading)
                .help(loc.t("Dibuja en un mapa lo que la respuesta consultó.",
                            "Draws on a map what the answer looked up."))
                if loading {
                    ProgressView().controlSize(.small)
                    Text(loc.t("Cargando el mapa…", "Loading the map…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if failed {
                    Text(loc.t("No se pudo cargar el mapa", "The map could not be loaded"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Apple Maps data may only be shown on an Apple map; every other map draws with MapLibre, also without internet.
    @ViewBuilder
    private func canvas(_ map: ChatMap) -> some View {
        if map.layers.contains(where: \.isApple) {
            ChatMapCanvas(map: map, onSelect: { selected = $0 })
        } else {
            ChatMapLibreCanvas(map: map, onSelect: { selected = $0 })
        }
    }

    @ViewBuilder
    private func legend(_ map: ChatMap) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(map.layers.enumerated()), id: \.offset) { index, layer in
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: ChatMapCanvas.color(index))).frame(width: 8, height: 8)
                        Text(layer.title ?? loc.t("Capa", "Layer")).font(.caption.weight(.medium))
                        if let subtitle = layer.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let count = layer.count {
                            Text("(\(count))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let title = layer.linkTitle, let url = layer.linkURL.flatMap(URL.init(string:)) {
                            Button(loc.t("Abrir en %@", "Open in %@", title)) { NSWorkspace.shared.open(url) }
                                .buttonStyle(.link).font(.caption)
                                .help(loc.t("Abre la capa en su visor original, en el navegador.",
                                            "Opens the layer in its own viewer, in the browser."))
                        }
                    }
                }
            }
            Spacer()
            ChatFigureResizeButton(enlarged: enlarged) { enlarged.toggle() }
            Button(loc.t("Exportar GeoJSON", "Export GeoJSON")) { export(map) }
                .buttonStyle(.link).font(.caption)
                .help(loc.t("Guarda lo dibujado en archivos que abren QGIS y otras aplicaciones GIS: uno por capa y tipo de geometría, como los toman sus herramientas de importación.",
                            "Saves what is drawn to files that QGIS and other GIS applications open: one per layer and kind of geometry, as their import tools take them."))
        }
    }

    private func export(_ map: ChatMap) {
        let files = map.exportFiles()
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = loc.t("Exportar aquí", "Export here")
        panel.message = loc.t("Un archivo .geojson por capa y tipo de geometría: %@",
                              "One .geojson file per layer and kind of geometry: %@",
                              files.map(\.name).joined(separator: ", "))
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        for file in files {
            try? file.data.write(to: folder.appendingPathComponent(file.name))
        }
    }
}

extension ChatMap {
    /// The drawn features as GeoJSON files with one kind of geometry each: a GIS layer holds a single kind,
    /// and import tools take one kind per run.
    func exportFiles() -> [(name: String, data: Data)] {
        let kinds: [(suffix: String, types: Set<String>)] = [
            ("polygons", ["Polygon", "MultiPolygon"]), ("lines", ["LineString", "MultiLineString"]),
            ("points", ["Point"]), ("multipoints", ["MultiPoint"])]
        var files: [(name: String, data: Data)] = []
        var taken = Set<String>()
        for (index, layer) in layers.enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: layer.geojson) as? [String: Any],
                  let items = object["features"] as? [[String: Any]] else { continue }
            let title = layer.title ?? "map"
            let groups = kinds.map { kind in
                items.filter { kind.types.contains(($0["geometry"] as? [String: Any])?["type"] as? String ?? "") }
            }
            let used = groups.filter { !$0.isEmpty }.count
            for (kind, group) in zip(kinds, groups) where !group.isEmpty {
                let features = group.map { item -> [String: Any] in
                    var item = item
                    var properties = item["properties"] as? [String: Any] ?? [:]
                    properties["layer"] = title
                    item["properties"] = properties
                    return item
                }
                let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
                guard let data = try? JSONSerialization.data(withJSONObject: collection, options: [.prettyPrinted]) else { continue }
                var stem = Self.fileStem(title) + (used > 1 ? " - \(kind.suffix)" : "")
                if taken.contains(stem) { stem += " \(index + 1)" }
                taken.insert(stem)
                files.append((stem + ".geojson", data))
            }
        }
        return files
    }

    static func fileStem(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "map" : cleaned).prefix(80))
    }
}

/// The attributes of the clicked feature, as a GIS shows a feature's pop-up.
struct ChatMapFeatureCard: View {
    let feature: ChatMapFeature
    let onClose: () -> Void

    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: ChatMapCanvas.color(feature.layer))).frame(width: 8, height: 8)
                Text(feature.title ?? loc.t("Elemento", "Feature")).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(loc.t("Cerrar", "Close"))
            }
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(Array(feature.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label).font(.caption).foregroundStyle(.secondary)
                            Text(row.value).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(10)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
    }
}

/// An Apple map with the layers' GeoJSON drawn on it, framed on what they hold. A click on a feature reports
/// its attributes; a click on a group of markers zooms in to separate them.
struct ChatMapCanvas: NSViewRepresentable {
    let map: ChatMap
    let onSelect: (ChatMapFeature?) -> Void

    static func color(_ index: Int) -> NSColor {
        [NSColor.systemBlue, .systemOrange, .systemGreen, .systemPurple][index % 4]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.showsZoomControls = true
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        context.coordinator.onSelect = onSelect
        draw(on: view, context.coordinator)
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        guard context.coordinator.drawn != map else { return }
        view.removeOverlays(view.overlays)
        view.removeAnnotations(view.annotations)
        draw(on: view, context.coordinator)
    }

    private func draw(on view: MKMapView, _ coordinator: Coordinator) {
        coordinator.drawn = map
        coordinator.colors = [:]
        coordinator.features = [:]
        coordinator.dashed = []
        var frame = MKMapRect.null
        for (index, layer) in map.layers.enumerated() {
            guard let objects = try? MKGeoJSONDecoder().decode(layer.geojson) else { continue }
            for case let feature as MKGeoJSONFeature in objects {
                let properties = Self.properties(feature)
                let info = Self.feature(properties, layer: layer, index: index)
                for shape in feature.geometry {
                    if let overlay = shape as? MKOverlay {
                        coordinator.colors[ObjectIdentifier(overlay)] = Self.color(index)
                        coordinator.features[ObjectIdentifier(overlay)] = info
                        if layer.drawn == true { coordinator.dashed.insert(ObjectIdentifier(overlay)) }
                        view.addOverlay(overlay)
                        frame = frame.union(overlay.boundingMapRect)
                    } else if let point = shape as? MKPointAnnotation {
                        let marker = FeatureAnnotation(info: info)
                        marker.coordinate = point.coordinate
                        marker.title = Self.name(properties)
                        coordinator.colors[ObjectIdentifier(marker)] = Self.color(index)
                        view.addAnnotation(marker)
                        let at = MKMapPoint(point.coordinate)
                        frame = frame.union(MKMapRect(x: at.x, y: at.y, width: 0, height: 0))
                    }
                }
            }
        }
        guard !frame.isNull else { return }
        // a single point or a tiny shape still gets a readable neighborhood around it
        let side = max(frame.width, frame.height, 2000)
        let framed = MKMapRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
        view.setVisibleMapRect(frame.width > 2000 || frame.height > 2000 ? frame : framed,
                               edgePadding: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), animated: false)
    }

    private static func properties(_ feature: MKGeoJSONFeature) -> [String: Any] {
        guard let data = feature.properties,
              let properties = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return properties
    }

    /// The feature's name for its marker: a property that looks like one, else none.
    private static func name(_ properties: [String: Any]) -> String? {
        let named = properties.first { key, value in
            value is String && key.range(of: "name|nombre|title|site|company", options: [.regularExpression, .caseInsensitive]) != nil
        }
        return named?.value as? String
    }

    /// The attributes to read, in the layer's order and with its names, without ids and geometry sizes.
    static func feature(_ properties: [String: Any], layer: ChatMap.Layer, index: Int) -> ChatMapFeature {
        let hidden = try? NSRegularExpression(pattern: "^(objectid(_\\d+)?|fid|globalid|shape_?_?(area|length|leng|len))$",
                                              options: .caseInsensitive)
        let order = (layer.fields ?? []).map(\.name)
        let aliases = Dictionary((layer.fields ?? []).map { ($0.name, $0.alias) }, uniquingKeysWith: { first, _ in first })
        let names = order.filter { properties[$0] != nil } + properties.keys.filter { !order.contains($0) }.sorted()
        let rows = names.compactMap { name -> ChatMapFeature.Row? in
            let range = NSRange(name.startIndex..., in: name)
            guard hidden?.firstMatch(in: name, range: range) == nil, let value = format(properties[name]) else { return nil }
            return ChatMapFeature.Row(label: aliases[name] ?? name, value: value)
        }
        return ChatMapFeature(layer: index, title: name(properties) ?? layer.title, rows: rows)
    }

    private static func format(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull: return nil
        case let text as String: return text.isEmpty ? nil : text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = number.doubleValue.rounded() == number.doubleValue ? 0 : 4
            return formatter.string(from: number)
        default: return "\(value!)"
        }
    }

    final class FeatureAnnotation: MKPointAnnotation {
        let info: ChatMapFeature
        init(info: ChatMapFeature) {
            self.info = info
            super.init()
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var drawn: ChatMap?
        var colors: [ObjectIdentifier: NSColor] = [:]
        var features: [ObjectIdentifier: ChatMapFeature] = [:]
        var dashed: Set<ObjectIdentifier> = []
        var onSelect: (ChatMapFeature?) -> Void = { _ in }
        private weak var highlighted: MKOverlayPathRenderer?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let color = colors[ObjectIdentifier(overlay)] ?? .systemBlue
            let renderer: MKOverlayPathRenderer
            switch overlay {
            case let shape as MKMultiPolygon: renderer = MKMultiPolygonRenderer(multiPolygon: shape)
            case let shape as MKPolygon: renderer = MKPolygonRenderer(polygon: shape)
            case let shape as MKMultiPolyline: renderer = MKMultiPolylineRenderer(multiPolyline: shape)
            case let shape as MKPolyline: renderer = MKPolylineRenderer(polyline: shape)
            default: return MKOverlayRenderer(overlay: overlay)
            }
            renderer.strokeColor = color
            renderer.lineWidth = 1.5
            if dashed.contains(ObjectIdentifier(overlay)) { renderer.lineDashPattern = [6, 4] }
            if overlay is MKPolygon || overlay is MKMultiPolygon {
                renderer.fillColor = color.withAlphaComponent(0.2)
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "group") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: "group")
                view.annotation = cluster
                view.markerTintColor = cluster.memberAnnotations.first.flatMap { colors[ObjectIdentifier($0)] } ?? .systemBlue
                view.glyphText = "\(cluster.memberAnnotations.count)"
                return view
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "feature") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "feature")
            view.annotation = annotation
            view.markerTintColor = colors[ObjectIdentifier(annotation)] ?? .systemBlue
            view.clusteringIdentifier = "feature"
            view.canShowCallout = false
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            if let cluster = annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
            } else if let marker = annotation as? FeatureAnnotation {
                highlight(nil)
                onSelect(marker.info)
            }
        }

        /// A click on a line or an area: the topmost one under the pointer, if any.
        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            var hit = mapView.hitTest(mapView.convert(point, to: mapView.superview))
            while let view = hit, !(view is MKAnnotationView), view !== mapView { hit = view.superview }
            if hit is MKAnnotationView { return }
            let at = MKMapPoint(mapView.convert(point, toCoordinateFrom: mapView))
            // a few pixels of slack, in map points, so a thin line can be hit
            let slack = 6 * mapView.visibleMapRect.width / max(mapView.bounds.width, 1)
            for overlay in mapView.overlays.reversed() {
                guard let renderer = mapView.renderer(for: overlay) as? MKOverlayPathRenderer,
                      overlay.boundingMapRect.insetBy(dx: -slack, dy: -slack).contains(at) else { continue }
                if renderer.path == nil { renderer.createPath() }
                guard let path = renderer.path else { continue }
                let local = renderer.point(for: at)
                let filled = overlay is MKPolygon || overlay is MKMultiPolygon
                let inside = filled ? path.contains(local)
                    : path.copy(strokingWithWidth: slack * 2, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(local)
                if inside, let info = features[ObjectIdentifier(overlay)] {
                    mapView.selectedAnnotations.forEach { mapView.deselectAnnotation($0, animated: false) }
                    highlight(renderer)
                    onSelect(info)
                    return
                }
            }
            highlight(nil)
            onSelect(nil)
        }

        private func highlight(_ renderer: MKOverlayPathRenderer?) {
            if let previous = highlighted {
                previous.lineWidth = 1.5
                previous.setNeedsDisplay()
            }
            highlighted = renderer
            renderer?.lineWidth = 4
            renderer?.setNeedsDisplay()
        }
    }
}
