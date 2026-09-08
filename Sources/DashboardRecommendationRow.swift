// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct DashboardRecommendationRow: View {
    let rec: Catalog.Recommendation
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                roleBadge.frame(width: 98, alignment: .leading)
                identity.frame(minWidth: 165, maxWidth: .infinity, alignment: .leading)
                column(rec.est.expectedSpeed, detail: loc.t("Velocidad estimada", "Estimated speed"), icon: "bolt")
                    .frame(width: 140, alignment: .leading)
                column(String(format: "%.1f GB", rec.est.vramGB), detail: "VRAM", icon: "internaldrive")
                    .frame(width: 85, alignment: .leading)
                compatibility.frame(width: 110, alignment: .leading)
                CatalogActionButton(model: rec.model, est: rec.est).frame(width: 112)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    identity
                    HStack(spacing: 12) {
                        roleBadge
                        Text(rec.est.expectedSpeed).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(String(format: "%.1f GB VRAM", rec.est.vramGB)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                CatalogActionButton(model: rec.model, est: rec.est)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.border))
        .help(rec.model.detail(loc.isSpanish))
    }

    private var identity: some View {
        HStack(spacing: 12) {
            ModelBrandIcon(name: rec.model.name)
            VStack(alignment: .leading, spacing: 5) {
                Text(ModelName(rec.model.name).title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(rec.model.isVision ? loc.t("Visión · Multimodal", "Vision · Multimodal") : rec.model.isCoder ? loc.t("Código · Agentes", "Code · Agents") : rec.model.spec.isMoE ? "MoE" : loc.t("Uso general", "General purpose"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var roleBadge: some View {
        Label(role.text, systemImage: role.icon)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .foregroundStyle(role.color)
            .background(role.color.opacity(0.13), in: Capsule())
            .fixedSize()
    }

    private var role: (text: String, icon: String, color: Color) {
        switch rec.role {
        case .fast: return (loc.t("RÁPIDO", "FASTEST"), "hare.fill", .green)
        case .balanced: return (loc.t("EQUILIBRADO", "BALANCED"), "sparkles", .blue)
        case .quality: return (loc.t("CALIDAD", "QUALITY"), "star.fill", .orange)
        case .coding: return (loc.t("CÓDIGO", "CODING"), "chevron.left.forwardslash.chevron.right", .purple)
        }
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(compatibilityLabel, systemImage: rec.est.level == .no ? "xmark.circle.fill" : "circle.fill")
                .font(.system(size: 12)).foregroundStyle(rec.est.level == .ideal ? .green : .orange)
            Text(loc.t("Compatibilidad", "Compatibility")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var compatibilityLabel: String {
        switch rec.est.level {
        case .ideal: return loc.t("GPU completa", "Full GPU")
        case .good: return loc.t("Híbrido", "Hybrid")
        case .slow: return loc.t("Lento", "Slow")
        case .no: return loc.t("No cabe", "Won’t fit")
        }
    }

    private func column(_ value: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(value, systemImage: icon).font(.system(size: 12))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
