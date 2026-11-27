// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class ChatCapabilityTests: XCTestCase {
    func testThinkingSupportRecognizesTemplateControls() {
        XCTAssertTrue(ThinkingSupportDetector.supportsThinking("{% if enable_thinking %}<think>{% endif %}"))
        XCTAssertTrue(ThinkingSupportDetector.supportsThinking("{{ reasoning_effort }}"))
        XCTAssertFalse(ThinkingSupportDetector.supportsThinking("{{ messages | tojson }}"))
    }

    func testReasoningEffortBudgetsMatchLlamaUILevels() {
        XCTAssertNil(ChatStore.reasoningBudget(for: "off"))
        XCTAssertEqual(ChatStore.reasoningBudget(for: "low"), 512)
        XCTAssertEqual(ChatStore.reasoningBudget(for: "medium"), 2_048)
        XCTAssertEqual(ChatStore.reasoningBudget(for: "high"), 8_192)
        XCTAssertNil(ChatStore.reasoningBudget(for: "max"))
    }

    func testReasoningEffortDetectorReadsTheValidatedSet() {
        // Verbatim from Qwen3.8-27B, the model reported in issue #68.
        let template = """
        {%- if enable_thinking is undefined or enable_thinking is true %}
            {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
            {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
                {{- raise_exception('Unexpected reasoning effort ' ~ reasoning_effort ~ '. Supported types are xhigh (default), medium, and low.') }}
            {%- endif %}
            {%- if resolved_reasoning_effort == 'xhigh' %}
                {%- set reasoning_instructions = 'Reasoning effort is set to xhigh.' %}
            {%- endif %}
        {%- endif %}
        """
        let support = ReasoningEffortDetector.detect(template)
        XCTAssertEqual(support.levels, ["low", "medium", "xhigh"])
        XCTAssertEqual(support.modelDefault, "xhigh")
    }

    func testReasoningEffortDetectorReadsTheDefaultAssignment() {
        let hunyuan = """
        {%- if not reasoning_effort is defined %}
            {%- set reasoning_effort = 'no_think' %}
        {%- elif reasoning_effort not in ['high', 'low', 'no_think'] %}
            {{- raise_exception('reasoning_effort error') }}
        {%- endif %}
        {%- set reasoning_effort = 'high' %}
        """
        let support = ReasoningEffortDetector.detect(hunyuan)
        XCTAssertEqual(support.levels, ["no_think", "low", "high"])
        XCTAssertEqual(support.modelDefault, "no_think")

        let gptoss = """
        {%- if reasoning_effort is not defined %}
            {%- set reasoning_effort = "medium" %}
        {%- endif %}
        {{- "Reasoning: " + reasoning_effort }}
        """
        let open = ReasoningEffortDetector.detect(gptoss)
        XCTAssertTrue(open.levels.isEmpty)
        XCTAssertEqual(open.modelDefault, "medium")
    }

    func testReasoningEffortDetectorIgnoresBranchesAndPlainTemplates() {
        // A branch that only words the prompt is not the accepted set.
        let solar = """
        {%- set reasoning_effort = reasoning_effort if reasoning_effort is defined else "high" %}
        {%- if reasoning_effort in ["low", "minimal"] -%}be brief{%- endif -%}
        """
        let support = ReasoningEffortDetector.detect(solar)
        XCTAssertTrue(support.levels.isEmpty)
        XCTAssertEqual(support.modelDefault, "high")

        let plain = ReasoningEffortDetector.detect("{% for message in messages %}{{ message.content }}{% endfor %}")
        XCTAssertTrue(plain.levels.isEmpty)
        XCTAssertNil(plain.modelDefault)
    }

    func testModelDefaultEffortSendsNoBudget() {
        XCTAssertNil(ChatStore.reasoningBudget(for: "default"))
        XCTAssertNil(ChatStore.reasoningBudget(for: "xhigh"))
    }

    /// The budget ladder keeps its order: a lower level never gets more room.
    func testReasoningBudgetsRiseWithTheLevel() {
        let capped = ["minimal", "low", "medium", "high"].map { ChatStore.reasoningBudget(for: $0)! }
        XCTAssertEqual(capped, capped.sorted())
        XCTAssertEqual(ChatStore.reasoningBudget(for: "minimal"), 128)
    }

    func testUnsupportedEffortFallsBackWithoutLiftingTheBudget() {
        let ridge = ["low", "medium", "xhigh"]
        XCTAssertEqual(ReasoningEffortDetector.closest(to: "high", in: ridge), "medium")
        XCTAssertEqual(ReasoningEffortDetector.closest(to: "max", in: ridge), "xhigh")
        XCTAssertEqual(ReasoningEffortDetector.closest(to: "medium", in: ridge), "medium")
        XCTAssertEqual(ReasoningEffortDetector.closest(to: "minimal", in: ridge), "low")
        XCTAssertNil(ReasoningEffortDetector.closest(to: "brisk", in: ridge))
    }

    func testClampedReasoningBudgetPreservesAnswerReserve() {
        // default maxTokens (8192) clamps "high" (8192) to keep room for the answer.
        XCTAssertEqual(ChatStore.clampedReasoningBudget(for: "high", maxTokens: 8_192), 7_424)
        XCTAssertEqual(ChatStore.clampedReasoningBudget(for: "medium", maxTokens: 8_192), 2_048)
        XCTAssertEqual(ChatStore.clampedReasoningBudget(for: "low", maxTokens: 8_192), 512)
        XCTAssertEqual(ChatStore.clampedReasoningBudget(for: "minimal", maxTokens: 8_192), 128)
        // Small T9-like turn budgets still leave room for visible output.
        XCTAssertEqual(ChatStore.clampedReasoningBudget(for: "high", maxTokens: 4_096), 3_328)
        XCTAssertEqual(ChatStore.clampedReasoningBudget(for: "high", maxTokens: 512), 256)
        // Open/off levels remain nil.
        XCTAssertNil(ChatStore.clampedReasoningBudget(for: "default", maxTokens: 8_192))
        XCTAssertNil(ChatStore.clampedReasoningBudget(for: "off", maxTokens: 8_192))
    }

    func testAutoFinalizeEmptyResponseTriggersAtMostOnceForEmptyStopOrThinkingCut() {
        // Triggers after empty reasoning cutoff or empty stop.
        XCTAssertTrue(ChatStore.shouldAutoFinalizeEmptyResponse(
            wasCancelled: false, didReportError: false, shouldDeliverQueued: false,
            hasVisibleAnswer: false, hasToolCalls: false, hasClosing: false,
            alreadyFinalizing: false, hadReasoning: true, inAgentLoop: false,
            finishReason: "length"
        ))
        XCTAssertTrue(ChatStore.shouldAutoFinalizeEmptyResponse(
            wasCancelled: false, didReportError: false, shouldDeliverQueued: false,
            hasVisibleAnswer: false, hasToolCalls: false, hasClosing: false,
            alreadyFinalizing: false, hadReasoning: false, inAgentLoop: true,
            finishReason: "stop"
        ))
        XCTAssertTrue(ChatStore.shouldAutoFinalizeEmptyResponse(
            wasCancelled: false, didReportError: false, shouldDeliverQueued: false,
            hasVisibleAnswer: false, hasToolCalls: false, hasClosing: false,
            alreadyFinalizing: false, hadReasoning: false, inAgentLoop: false,
            finishReason: "stop"
        ))
        // Guarded against loops, visible answers, tool calls, cancellations, and transport drops.
        XCTAssertFalse(ChatStore.shouldAutoFinalizeEmptyResponse(
            wasCancelled: false, didReportError: false, shouldDeliverQueued: false,
            hasVisibleAnswer: false, hasToolCalls: false, hasClosing: false,
            alreadyFinalizing: true, hadReasoning: true, inAgentLoop: true,
            finishReason: "stop"
        ))
        XCTAssertFalse(ChatStore.shouldAutoFinalizeEmptyResponse(
            wasCancelled: false, didReportError: false, shouldDeliverQueued: false,
            hasVisibleAnswer: true, hasToolCalls: false, hasClosing: false,
            alreadyFinalizing: false, hadReasoning: true, inAgentLoop: false,
            finishReason: "stop"
        ))
        XCTAssertFalse(ChatStore.shouldAutoFinalizeEmptyResponse(
            wasCancelled: false, didReportError: false, shouldDeliverQueued: false,
            hasVisibleAnswer: false, hasToolCalls: true, hasClosing: false,
            alreadyFinalizing: false, hadReasoning: true, inAgentLoop: false,
            finishReason: "tool_calls"
        ))
        XCTAssertFalse(ChatStore.shouldAutoFinalizeEmptyResponse(
            wasCancelled: false, didReportError: false, shouldDeliverQueued: false,
            hasVisibleAnswer: false, hasToolCalls: false, hasClosing: false,
            alreadyFinalizing: false, hadReasoning: false, inAgentLoop: false,
            finishReason: nil
        ))
    }

    func testAutoFinalizeEmptyResponseSkipsServerAgentTurnsEvenAfterReasoningOrStop() {
        XCTAssertFalse(ChatStore.shouldAutoFinalizeEmptyResponse(
            wasServerAgentTurn: true,
            wasCancelled: false, didReportError: false, shouldDeliverQueued: false,
            hasVisibleAnswer: false, hasToolCalls: false, hasClosing: false,
            alreadyFinalizing: false, hadReasoning: true, inAgentLoop: true,
            finishReason: "stop"
        ))
        XCTAssertFalse(ChatStore.shouldAutoFinalizeEmptyResponse(
            wasServerAgentTurn: true,
            wasCancelled: false, didReportError: false, shouldDeliverQueued: false,
            hasVisibleAnswer: false, hasToolCalls: false, hasClosing: false,
            alreadyFinalizing: false, hadReasoning: false, inAgentLoop: false,
            finishReason: "length"
        ))
    }
}
