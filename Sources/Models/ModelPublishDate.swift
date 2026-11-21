// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// When a model was published on Hugging Face. A quantized repository appears after the model
/// it was made from, so the base model's date wins when the card names one.
struct ModelPublishDate: Equatable, Sendable {
    let date: Date
    /// The repository the date belongs to: the base model, or the model's own.
    let repository: String

    private struct Info: Decodable {
        struct Card: Decodable {
            let baseModel: [String]

            enum CodingKeys: String, CodingKey { case baseModel = "base_model" }

            // the card gives one name or a list of them
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let one = try? container.decode(String.self, forKey: .baseModel) {
                    baseModel = [one]
                } else {
                    baseModel = (try? container.decode([String].self, forKey: .baseModel)) ?? []
                }
            }
        }
        let createdAt: Date?
        let cardData: Card?
    }

    /// The creation date and first base model of a `/api/models/<repo>` answer.
    nonisolated static func parse(_ data: Data) -> (created: Date?, base: String?) {
        guard let info = try? SearchStore.decoder.decode(Info.self, from: data) else { return (nil, nil) }
        let created = info.createdAt.flatMap { $0 > .distantPast ? $0 : nil }
        return (created, info.cardData?.baseModel.first)
    }

    private actor Cache {
        private var values: [String: ModelPublishDate] = [:]
        func value(for repository: String) -> ModelPublishDate? { values[repository] }
        func store(_ value: ModelPublishDate, for repository: String) { values[repository] = value }
    }
    private static let cache = Cache()

    static func fetch(repository: String) async -> ModelPublishDate? {
        if let hit = await cache.value(for: repository) { return hit }
        guard let own = await info(repository) else { return nil }
        var result = own.created.map { ModelPublishDate(date: $0, repository: repository) }
        if let base = own.base, base != repository, let created = await info(base)?.created,
           result.map({ created < $0.date }) ?? true {
            result = ModelPublishDate(date: created, repository: base)
        }
        if let result { await cache.store(result, for: repository) }
        return result
    }

    private static func info(_ repository: String) async -> (created: Date?, base: String?)? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repository)"),
              let (data, response) = try? await HubEndpoint.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
