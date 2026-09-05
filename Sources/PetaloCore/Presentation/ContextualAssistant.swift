import Foundation

/// The display on which an assistant action began. It deliberately retains no
/// `NSScreen` reference so the workflow remains deterministic and testable.
public struct AssistantInvocationDisplay: Equatable, Sendable {
    public let id: UInt32

    public init(id: UInt32) {
        self.id = id
    }
}

/// Content collected before Petalo activates its key-capable prompt panel.
/// Image bytes are kept in memory by the caller and are never assigned a file
/// URL by this model. The `.none` case represents a direct (hover-initiated)
/// prompt with no captured context — the user just types and sends.
public enum AssistantContext: Equatable, Sendable {
    case selectedText(String)
    case capturedImage(AssistantImagePayload)
    case none
}

public struct AssistantImagePayload: Equatable, Sendable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String = "image/png") {
        self.data = data
        self.mimeType = mimeType
    }
}

/// The typed, in-memory handoff to a destination. Text and image contexts are
/// intentionally mutually exclusive for this MVP.
public struct AssistantPayload: Equatable, Sendable {
    public let instruction: String
    public let context: AssistantContext

    public init(instruction: String, context: AssistantContext) {
        self.instruction = instruction
        self.context = context
    }
}

public enum AssistantWorkflowFailure: Equatable, Sendable {
    case accessibilityDenied
    case selectedTextUnavailable
    case screenRecordingDenied
    case invalidRegionSelection
    case captureFailed
    case emptyInstruction
    case destinationUnavailable
    case deliveryFailed
}

public enum AssistantDeliveryResult: Equatable, Sendable {
    /// A destination completed an explicitly supported delivery.
    case completed
    /// Petalo has safely prepared content, but the user must paste and send it.
    case manualCompletionRequired
    case failed(AssistantWorkflowFailure)
}

/// Destination boundary for future providers. Implementations may complete
/// delivery automatically when a supported compose path exists, or fall back
/// to a manual-completion result for providers without one.
@MainActor
public protocol AssistantDestination: AnyObject {
    func deliver(_ payload: AssistantPayload) async -> AssistantDeliveryResult
}

public enum ChatGPTDesktopCapability: Equatable, Sendable {
    case unavailable
    case autoPaste
}

/// ChatGPT's desktop app has no documented inbound composition API, so Petalo
/// routes through synthetic keyboard events: it copies the prepared prompt to
/// the clipboard, opens ChatGPT, simulates paste, and presses Return. The
/// policy maps an availability failure to a safe error and an installed app
/// to a completed automatic delivery.
public enum ChatGPTDeliveryPolicy {
    public static func result(for capability: ChatGPTDesktopCapability) -> AssistantDeliveryResult {
        switch capability {
        case .unavailable:
            .failed(.destinationUnavailable)
        case .autoPaste:
            .completed
        }
    }
}

/// Retry schedule for a ChatGPT handoff step. Pure and testable: given a
/// zero-based attempt index, `delay(forAttempt:)` returns the nanoseconds to
/// wait before the next verification probe, or `nil` when the schedule is
/// exhausted (the caller should give up). The schedule starts short so a fast
/// machine wastes no time, then grows geometrically up to a ceiling so a slow
/// app launch or a temporarily stolen focus still converges.
///
/// Two preset schedules cover the two resilience needs:
/// - `.activation` is patient (up to 8 attempts) and is used after opening
///   ChatGPT to wait until it is actually the frontmost app — this is the
///   fix for the "keystrokes fire before the window is focused" race.
/// - `.recovery` is short (3 attempts) and is used before each synthetic
///   keystroke to re-verify focus has not drifted mid-handoff.
public struct ChatGPTHandoffTiming: Equatable, Sendable {
    public let initialDelayNs: UInt64
    public let maxDelayNs: UInt64
    public let backoffFactor: Double
    public let maxAttempts: Int

    public init(
        initialDelayNs: UInt64,
        maxDelayNs: UInt64,
        backoffFactor: Double,
        maxAttempts: Int
    ) {
        self.initialDelayNs = initialDelayNs
        self.maxDelayNs = maxDelayNs
        self.backoffFactor = backoffFactor
        self.maxAttempts = maxAttempts
    }

    /// Patient schedule for waiting on ChatGPT activation after `openApplication`.
    public static let activation = ChatGPTHandoffTiming(
        initialDelayNs: 100_000_000,
        maxDelayNs: 800_000_000,
        backoffFactor: 2.0,
        maxAttempts: 8
    )

    /// Short schedule for re-verifying focus before each synthetic keystroke.
    public static let recovery = ChatGPTHandoffTiming(
        initialDelayNs: 80_000_000,
        maxDelayNs: 400_000_000,
        backoffFactor: 2.0,
        maxAttempts: 3
    )

    /// Nanoseconds to wait before the given zero-based attempt, or `nil` when
    /// `attempt` is outside `[0, maxAttempts)` and the caller should give up.
    public func delay(forAttempt attempt: Int) -> UInt64? {
        guard attempt >= 0, attempt < maxAttempts else { return nil }
        let raw = Double(initialDelayNs) * pow(backoffFactor, Double(attempt))
        let clamped = min(raw, Double(maxDelayNs))
        return UInt64(clamped)
    }
}

/// Explicit clipboard operations for a destination. Image content
/// intentionally is not a second representation on a text pasteboard item:
/// the destination copies and pastes each step independently.
public enum ManualCompletionStep: Equatable, Sendable {
    case copyPrompt(String)
    case copyImage(AssistantImagePayload)
}

public enum ManualCompletionPlan {
    public static func steps(for payload: AssistantPayload) -> [ManualCompletionStep] {
        switch payload.context {
        case let .selectedText(selection):
            return [.copyPrompt("\(payload.instruction)\n\nSelected text:\n\(selection)")]
        case let .capturedImage(image):
            return [.copyPrompt(payload.instruction), .copyImage(image)]
        case .none:
            return [.copyPrompt(payload.instruction)]
        }
    }

    /// The combined text prompt for automatic paste. For a selected-text
    /// handoff this is the instruction and selection together; for an image
    /// it is just the instruction (the image is pasted separately); for a
    /// direct (no-context) prompt it is just the instruction.
    public static func combinedPromptText(for payload: AssistantPayload) -> String {
        switch payload.context {
        case let .selectedText(selection):
            "\(payload.instruction)\n\nSelected text:\n\(selection)"
        case .capturedImage:
            payload.instruction
        case .none:
            payload.instruction
        }
    }
}

/// The ordered operations a ChatGPT desktop handoff performs after ChatGPT
/// is frontmost. Exposed as a pure, testable value type in PetaloCore so the
/// behavioral test can guard the invariant that protects the paste from
/// clipboard-manager interference: every clipboard write is the last step
/// before its paste, with no delay or focus re-check between them.
///
/// A clipboard manager that auto-restores the prior clipboard contents after
/// detecting a programmatic change (Maccy, Paste, Raycast, …) can replace
/// the prompt between the write and the paste if any `verifyFrontmost` or
/// `wait` step separates them. Keeping the write flush against the paste —
/// both are synchronous on the main actor with no `await` between them —
/// means the manager's async notification handler cannot fire before the
/// paste reads the clipboard.
public enum ChatGPTHandoffPlan {
    public enum Step: Equatable, Sendable {
        case verifyFrontmost
        case newConversation
        case waitNanoseconds(UInt64)
        case writeClipboard(ManualCompletionStep)
        case paste
        case sendReturn
    }

    /// Wait after Cmd+N for ChatGPT to open the new conversation and focus its
    /// compose field before the next keystroke. Too short and the paste lands
    /// in the previously open conversation — the prompt is appended to an
    /// existing thread instead of starting a fresh one. 1.2s covers the
    /// window/tab open and first-responder settling on a typical machine
    /// without making a fast one feel sluggish.
    public static let newConversationSettleNanoseconds: UInt64 = 1_200_000_000

    /// Steps for a text-only handoff (selected-text or direct prompt).
    public static func textSteps(for payload: AssistantPayload) -> [Step] {
        let text = ManualCompletionPlan.combinedPromptText(for: payload)
        return [
            .verifyFrontmost,
            .newConversation,
            .waitNanoseconds(newConversationSettleNanoseconds),
            .verifyFrontmost,
            .writeClipboard(.copyPrompt(text)),
            .paste,
            .waitNanoseconds(300_000_000),
            .verifyFrontmost,
            .sendReturn,
        ]
    }

    /// Steps for an image-then-text handoff. When the instruction is empty
    /// the text clipboard write and its paste are omitted entirely — pasting
    /// empty text into ChatGPT's compose field after the image is at best a
    /// no-op and at worst disrupts the attachment — so an image-only handoff
    /// writes the image, pastes it, and sends Return. The write→paste
    /// invariant (no async step between a clipboard write and its paste) is
    /// preserved for both the image and the optional text step.
    public static func imageThenTextSteps(for payload: AssistantPayload) -> [Step] {
        guard case let .capturedImage(image) = payload.context else { return [] }
        let text = ManualCompletionPlan.combinedPromptText(for: payload)
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var steps: [Step] = [
            .verifyFrontmost,
            .newConversation,
            .waitNanoseconds(newConversationSettleNanoseconds),
            .verifyFrontmost,
            .writeClipboard(.copyImage(image)),
            .paste,
        ]
        if hasText {
            steps.append(contentsOf: [
                .waitNanoseconds(400_000_000),
                .verifyFrontmost,
                .writeClipboard(.copyPrompt(text)),
                .paste,
            ])
        }
        steps.append(contentsOf: [
            .waitNanoseconds(300_000_000),
            .verifyFrontmost,
            .sendReturn,
        ])
        return steps
    }
}

public struct AssistantPromptDraft: Equatable, Sendable {
    public let display: AssistantInvocationDisplay
    public let context: AssistantContext
    public let sourceApplication: String?

    public init(
        display: AssistantInvocationDisplay,
        context: AssistantContext,
        sourceApplication: String?
    ) {
        self.display = display
        self.context = context
        self.sourceApplication = sourceApplication
    }
}

public enum AssistantWorkflowState: Equatable, Sendable {
    case idle
    case capturingSelectedText(display: AssistantInvocationDisplay)
    case selectingRegion(display: AssistantInvocationDisplay)
    case prompting(AssistantPromptDraft)
    case delivering
    /// A safe destination needs explicit user steps (for example, separately
    /// pasting a text instruction and image) before Petalo may clear payload.
    case manualCompletion
    case failed(AssistantWorkflowFailure)
}

/// Explicit state machine for contextual-assistant actions. The only states
/// that retain private content are `prompting`, `delivering`, and the explicit
/// `manualCompletion` flow; every terminal transition removes that data before
/// exposing the new state.
public struct ContextualAssistantWorkflow: Sendable {
    public private(set) var state: AssistantWorkflowState = .idle
    private var draft: AssistantPromptDraft?
    private var inFlightPayload: AssistantPayload?

    public init() {}

    public var hasSensitiveContext: Bool {
        draft != nil || inFlightPayload != nil
    }

    public var promptDraft: AssistantPromptDraft? {
        guard case .prompting = state else { return nil }
        return draft
    }

    /// Exposes the in-flight typed handoff only to a manual-completion panel.
    /// It becomes unavailable immediately after Done, Cancel, or failure.
    public var manualCompletionPayload: AssistantPayload? {
        guard case .manualCompletion = state else { return nil }
        return inFlightPayload
    }

    /// Begins a selected-text capture. A no-op while a delivery is in flight:
    /// the caller must first `abandonDelivery()` so the in-flight delivery's
    /// background task is cancelled and the state machine is free to accept a
    /// new capture. Without this guard, a second invocation would silently
    /// overwrite the `.delivering` state while the first delivery's keystrokes
    /// were still firing, causing the old payload to race the new one into
    /// ChatGPT.
    public mutating func beginSelectedTextCapture(on display: AssistantInvocationDisplay) {
        guard case .delivering = state else {
            clearSensitiveContext()
            state = .capturingSelectedText(display: display)
            return
        }
    }

    /// Begins a region selection. A no-op while a delivery is in flight, for
    /// the same reason as `beginSelectedTextCapture`.
    public mutating func beginRegionSelection(on display: AssistantInvocationDisplay) {
        guard case .delivering = state else {
            clearSensitiveContext()
            state = .selectingRegion(display: display)
            return
        }
    }

    /// Abandons an in-flight delivery: clears the payload and returns to
    /// `.idle`. The coordinator calls this after cancelling the delivery
    /// `Task`, so the state machine is free to accept a new capture. A no-op
    /// outside `.delivering`.
    public mutating func abandonDelivery() {
        guard case .delivering = state else { return }
        clearSensitiveContext()
        state = .idle
    }

    public mutating func captureSelectedText(_ text: String, sourceApplication: String?) {
        guard case let .capturingSelectedText(display) = state else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            captureFailed(.selectedTextUnavailable)
            return
        }
        let draft = AssistantPromptDraft(
            display: display,
            context: .selectedText(text),
            sourceApplication: sourceApplication
        )
        self.draft = draft
        state = .prompting(draft)
    }

    public mutating func captureRegion(
        _ image: AssistantImagePayload,
        sourceApplication: String? = nil
    ) {
        guard case let .selectingRegion(display) = state else { return }
        guard !image.data.isEmpty else {
            captureFailed(.captureFailed)
            return
        }
        let draft = AssistantPromptDraft(
            display: display,
            context: .capturedImage(image),
            sourceApplication: sourceApplication
        )
        self.draft = draft
        state = .prompting(draft)
    }

    /// Moves the private draft directly into an in-memory delivery payload. An
    /// invalid submission is terminal so an adapter cannot accidentally retain
    /// a previously captured selection after reporting an error.
    ///
    /// A captured image is a complete prompt on its own — the user may send a
    /// screenshot with no typed instruction — so an empty instruction is
    /// accepted when the draft carries an image. A text-bearing draft
    /// (selected text) still requires a non-empty instruction, since without
    /// one there is nothing to deliver.
    public mutating func beginDelivery(instruction: String) throws -> AssistantPayload {
        guard case .prompting = state, let draft else {
            throw AssistantWorkflowFailure.deliveryFailed
        }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresInstruction: Bool
        switch draft.context {
        case .capturedImage:
            requiresInstruction = false
        default:
            requiresInstruction = true
        }
        guard !trimmed.isEmpty || !requiresInstruction else {
            captureFailed(.emptyInstruction)
            throw AssistantWorkflowFailure.emptyInstruction
        }
        let payload = AssistantPayload(instruction: instruction, context: draft.context)
        self.draft = nil
        inFlightPayload = payload
        state = .delivering
        return payload
    }

    public mutating func captureFailed(_ failure: AssistantWorkflowFailure) {
        clearSensitiveContext()
        state = .failed(failure)
    }

    /// Delivers a direct (no-context) prompt submitted from the idle state —
    /// the hover-initiated path where the user types and sends without a
    /// shortcut or selection. Unlike `beginDelivery`, this does not require a
    /// captured draft: it builds a `.none` payload directly. An invalid
    /// submission is terminal so no stale state remains.
    public mutating func beginDirectDelivery(instruction: String) throws -> AssistantPayload {
        guard case .idle = state else {
            throw AssistantWorkflowFailure.deliveryFailed
        }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            captureFailed(.emptyInstruction)
            throw AssistantWorkflowFailure.emptyInstruction
        }
        let payload = AssistantPayload(instruction: instruction, context: .none)
        inFlightPayload = payload
        state = .delivering
        return payload
    }

    public mutating func completeDelivery(_ result: AssistantDeliveryResult) {
        switch result {
        case .completed:
            clearSensitiveContext()
            state = .idle
        case .manualCompletionRequired:
            guard inFlightPayload != nil else {
                state = .failed(.deliveryFailed)
                return
            }
            state = .manualCompletion
        case let .failed(failure):
            clearSensitiveContext()
            state = .failed(failure)
        }
    }

    public mutating func finishManualCompletion() {
        guard case .manualCompletion = state else { return }
        clearSensitiveContext()
        state = .idle
    }

    public mutating func cancel() {
        clearSensitiveContext()
        state = .idle
    }

    public mutating func dismissFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    private mutating func clearSensitiveContext() {
        draft = nil
        inFlightPayload = nil
    }
}

extension AssistantWorkflowFailure: Error {}
