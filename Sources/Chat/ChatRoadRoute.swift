// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MapKit

/// A route by road between points, from Apple Maps. The points go to Apple over the internet, so every call
/// waits for the user's approval; without it the model draws a straight line and says so.
enum ChatRoadRoute {
    static let toolName = "show_road_route"
    static let maximumStops = 10
    static let maximumLinePoints = 5_000

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.chatRoadRouteEnabled) as? Bool ?? true
    }

    /// What the model is told when the user turns the call down, so the answer still has a map.
    static let declined = "The user did not allow sending the points to Apple Maps over the internet. Draw a straight line between them with show_map instead, and say it is a straight line, not the road."

    static let tool: BuiltinToolInfo = try! BuiltinToolInfo(
        displayName: "Road route (Apple Maps)",
        name: toolName,
        writesData: false,
        definition: [
            "type": "function",
            "function": [
                "name": toolName,
                "description": "Finds the route by road between two or more points with Apple Maps and draws it on the map under your answer, with its distance and travel time. Use it when the user asks for a route by road, driving or walking directions, or the distance by road. It sends the points to Apple over the internet, so the user is asked first; if it is not allowed or fails, draw a straight line with show_map instead and say it is a straight line, not the road.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "maxLength": 120],
                        "stops": [
                            "type": "array",
                            "description": "Start, any stops in order, and destination",
                            "minItems": 2,
                            "maxItems": maximumStops,
                            "items": [
                                "type": "object",
                                "properties": ["lat": ["type": "number"], "lon": ["type": "number"],
                                               "label": ["type": "string", "maxLength": 120]],
                                "required": ["lat", "lon"]
                            ]
                        ],
                        "transport": ["type": "string", "enum": ["car", "walking"]]
                    ],
                    "required": ["stops"]
                ]
            ]
        ])

    struct Stop {
        let coordinate: CLLocationCoordinate2D
        let label: String
    }

    /// The stops of a call, or why it cannot be routed.
    static func stops(_ arguments: [String: Any]) -> (stops: [Stop], problem: String?) {
        let raw = (arguments["stops"] as? [[String: Any]]) ?? []
        var stops: [Stop] = []
        for (index, item) in raw.prefix(maximumStops).enumerated() {
            guard let lat = number(item["lat"]), let lon = number(item["lon"]), abs(lat) <= 90, abs(lon) <= 180 else {
                return ([], "stop \(index + 1) has no valid latitude and longitude")
            }
            let label = (item["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "stop \(index + 1)"
            stops.append(Stop(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), label: label))
        }
        return stops.count >= 2 ? (stops, nil) : ([], "a route needs at least two stops")
    }

    @MainActor
    static func route(arguments: [String: Any], loc: Localizer) async -> ChatMapTool.Drawn {
        let (stops, problem) = Self.stops(arguments)
        if let problem {
            return ChatMapTool.Drawn(result: ToolExecutionResult(content: "No road route: \(problem).", isError: true), map: nil)
        }
        let walking = (arguments["transport"] as? String) == "walking"
        var line: [[Double]] = []
        var meters = 0.0
        var seconds = 0.0
        do {
            for (from, to) in zip(stops, stops.dropFirst()) {
                let request = MKDirections.Request()
                request.source = mapItem(from.coordinate)
                request.destination = mapItem(to.coordinate)
                request.transportType = walking ? .walking : .automobile
                guard let route = try await MKDirections(request: request).calculate().routes.first else {
                    throw RouteError.none(from.label, to.label)
                }
                meters += route.distance
                seconds += route.expectedTravelTime
                var points = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: route.polyline.pointCount)
                route.polyline.getCoordinates(&points, range: NSRange(location: 0, length: points.count))
                line += points.map { [$0.longitude, $0.latitude] }
            }
        } catch {
            let reason = (error as? RouteError)?.description ?? error.localizedDescription
            return ChatMapTool.Drawn(result: ToolExecutionResult(
                content: "No road route: \(reason). Draw a straight line between the stops with show_map instead, and say it is a straight line, not the road.",
                isError: true), map: nil)
        }
        if line.count > maximumLinePoints {
            let step = Int((Double(line.count) / Double(maximumLinePoints)).rounded(.up))
            line = line.enumerated().filter { $0.offset % step == 0 || $0.offset == line.count - 1 }.map(\.element)
        }
        let kilometres = String(format: "%.1f km", meters / 1000)
        let time = duration(seconds)
        let names = stops.map(\.label).joined(separator: " → ")
        var features: [[String: Any]] = [["type": "Feature", "geometry": ["type": "LineString", "coordinates": line],
                                          "properties": ["name": names, "note": "\(kilometres), \(time)"]]]
        features += stops.map { ["type": "Feature",
                                 "geometry": ["type": "Point", "coordinates": [$0.coordinate.longitude, $0.coordinate.latitude]],
                                 "properties": ["name": $0.label]] }
        guard let geojson = try? JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features]) else {
            return ChatMapTool.Drawn(result: ToolExecutionResult(content: "No road route: the route could not be drawn.", isError: true), map: nil)
        }
        let mode = walking ? loc.t("a pie", "walking") : loc.t("en coche", "by car")
        let layer = ChatMap.Layer(
            title: (arguments["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? names,
            geojson: geojson, linkTitle: nil, linkURL: nil, complete: true,
            subtitle: loc.t("Ruta por carretera · Apple Maps · %@, %@ %@", "Road route · Apple Maps · %@, %@ %@",
                            kilometres, time, mode),
            fields: [ChatMap.Field(name: "name", alias: loc.t("Nombre", "Name")),
                     ChatMap.Field(name: "note", alias: loc.t("Nota", "Note"))],
            count: features.count, apple: true)
        let reply = "Road route drawn on the map under your answer (Apple Maps): \(names), \(kilometres), about \(time) \(walking ? "walking" : "by car"). These figures come from Apple Maps; give them as they are."
        return ChatMapTool.Drawn(result: ToolExecutionResult(content: reply, isError: false), map: ChatMap(layers: [layer]))
    }

    private enum RouteError: Error, CustomStringConvertible {
        case none(String, String)
        var description: String {
            switch self { case .none(let from, let to): "Apple Maps found no route from \(from) to \(to)" }
        }
    }

    private static func mapItem(_ coordinate: CLLocationCoordinate2D) -> MKMapItem {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            return MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        }
        #endif
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
