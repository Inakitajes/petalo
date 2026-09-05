import Foundation

import PetaloCore

enum TestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case let .expectation(message): message
        }
    }
}

func expect<T: Equatable>(_ actual: T, equals expected: T, _ message: String) throws {
    guard actual == expected else {
        throw TestFailure.expectation("\(message): expected \(expected), got \(actual)")
    }
}

func nativeNotchLayout() -> NotchLayout {
    NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 32,
        leftNotchEdgeX: 650,
        rightNotchEdgeX: 862,
        menuBarHeight: 24
    )
}

func testNativeDisplayUsesHardwareNotchPresentation() throws {
    let layout = nativeNotchLayout()

    try expect(layout.presentation, equals: .notch, "native display presentation")
    try expect(layout.topGap, equals: 0, "native notch stays attached to screen edge")
    try expect(layout.height, equals: 32, "native bar keeps safe-area height")
    try expect(layout.cornerStyle, equals: .hangingNotch, "native surface uses hanging corners")
    try expect(
        layout.compactBarLeadingOffset,
        equals: 650 - layout.compactLeadingWingWidth - layout.originX,
        "compact controls remain attached to the physical camera housing"
    )
}

/// Regression contract for the presentation that worked before the Petalo
/// refactor: an idle hardware notch keeps the original 48/28 pt wings, and
/// its early expansion keeps the same proportional hanging curve.
func testNativeNotchRestoresPreRefactorPaddingsAndTransitionCurve() throws {
    let layout = nativeNotchLayout()

    try expect(layout.compactLeadingWingWidth, equals: 48, "native leading wing width")
    try expect(layout.compactTrailingWingWidth, equals: 28, "native trailing wing width")
    try expect(
        layout.compactBarWidth,
        equals: layout.notchWidth + 76,
        "native compact bar uses the original idle paddings"
    )
    try expect(
        layout.compactBarLeadingOffset,
        equals: 650 - 48 - layout.originX,
        "native compact bar remains pinned to the physical camera housing"
    )

    let narrowHousing = NotchLayout(
        screenMinX: 0,
        screenWidth: 1_512,
        screenMaxY: 982,
        safeAreaTop: 24,
        leftNotchEdgeX: 500,
        rightNotchEdgeX: 640,
        menuBarHeight: 24
    )
    try expect(narrowHousing.notchWidth, equals: 168, "native housing keeps its original minimum width")

    let transitionPoint = DisplayPoint(x: 12, y: 12)
    try expect(
        HangingNotchGeometry.contains(
            transitionPoint,
            width: 200,
            height: 24,
            style: .hangingNotch,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "native transition uses the original proportional hanging curve"
    )
    try expect(
        HangingNotchGeometry.contains(
            DisplayPoint(x: 5, y: 5),
            width: 200,
            height: 24,
            style: .hangingNotch,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: false,
        "native transition still leaves the outer shoulder transparent"
    )
    try expect(
        HangingNotchGeometry.contains(
            transitionPoint,
            width: 200,
            height: 24,
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "external-display pill remains a bubble"
    )
}


func testNativeNotchShowsNoCompactMark() throws {
    let native = nativeNotchLayout()
    let external = NotchLayout(
        screenMinX: 100,
        screenWidth: 1_920,
        screenMaxY: 1_080,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )

    try expect(native.compactControlContent, equals: .none, "native compact control hides the petal mark from the leading corner")
    try expect(external.compactControlContent, equals: .brandLabel, "external pill keeps the Petalo label")
}

/// The petal glyph is retired from the collapsed bar on both presentations:
/// the hardware notch is pure glass, and the external pill keeps only the
/// "Petalo" wordmark.
func testCompactControlNeverShowsPetalMark() throws {
    let native = nativeNotchLayout()
    let external = NotchLayout(
        screenMinX: 100,
        screenWidth: 1_920,
        screenMaxY: 1_080,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )

    try expect(native.compactControlShowsPetalMark, equals: false, "native notch bar draws no petal glyph")
    try expect(external.compactControlShowsPetalMark, equals: false, "external pill draws no petal glyph, only the wordmark")
}

/// The collapsed pill hugs its label by an explicit padding rather than a
/// hardcoded width, so the two stay consistent when either is retuned.
func testCollapsedPillDerivesWidthFromExplicitPadding() throws {
    try expect(
        NotchLayout.pillCompactWidth,
        equals: NotchLayout.pillCompactContentWidth + 2 * NotchLayout.pillCompactHorizontalPadding,
        "pill width is content plus padding on both sides"
    )
    try expect(
        (NotchLayout.pillCompactWidth - NotchLayout.pillCompactContentWidth) / 2,
        equals: NotchLayout.pillCompactHorizontalPadding,
        "centering the label in the pill yields exactly that padding per side"
    )
}

func testExternalDisplayUsesContainedPillPresentation() throws {
    let layout = NotchLayout(
        screenMinX: 100,
        screenWidth: 1_920,
        screenMaxY: 1_080,
        safeAreaTop: 0,
        leftNotchEdgeX: nil,
        rightNotchEdgeX: nil,
        menuBarHeight: 24
    )

    try expect(layout.presentation, equals: .pill, "external display presentation")
    try expect(layout.cornerStyle, equals: .bubble, "external surface is a pill")
    try expect(layout.topGap, equals: NotchLayout.pillTopGap, "pill floats within menu bar")
    try expect(
        layout.height <= 24 - NotchLayout.pillTopGap - NotchLayout.pillBottomInset,
        equals: true,
        "pill stays inside external display menu bar"
    )
    try expect(
        layout.compactBarLeadingOffset,
        equals: (layout.width - NotchLayout.pillCompactWidth) / 2,
        "external pill is centered in the panel"
    )
}

func testPetaloExpandedCanvasDoesNotReserveSessionListHeight() throws {
    let layout = nativeNotchLayout()

    try expect(
        layout.expandedHeight <= layout.height + 200,
        equals: true,
        "Petalo expanded canvas remains independent of session-list height"
    )
    try expect(
        NotchLayout.expandedCanvasMaximumHeight,
        equals: 144,
        "Petalo reserves only its reusable UI canvas"
    )
}

func testScreenSelectionReturnsEveryDisplayInAllDisplaysMode() throws {
    let displays = [
        DisplaySnapshot(id: 9, frame: DisplayFrame(minX: 0, minY: 0, width: 1_512, height: 982)),
        DisplaySnapshot(id: 4, frame: DisplayFrame(minX: 1_512, minY: 0, width: 1_920, height: 1_080)),
    ]

    try expect(
        ScreenSelection.selectDisplayIDs(
            mode: .allDisplays,
            pointerLocation: nil,
            focusedDisplayID: nil,
            lastSelectedDisplayID: nil,
            displays: displays
        ),
        equals: [9, 4],
        "all displays receive an independent Petalo panel"
    )
}

func testFocusedWindowModeFallsBackWithoutWindowGeometry() throws {
    let displays = [
        DisplaySnapshot(id: 1, frame: DisplayFrame(minX: 0, minY: 0, width: 1_512, height: 982)),
        DisplaySnapshot(id: 2, frame: DisplayFrame(minX: 1_512, minY: 0, width: 1_920, height: 1_080)),
    ]

    try expect(
        ScreenSelection.selectDisplayID(
            mode: .focusedWindow,
            pointerLocation: DisplayPoint(x: 1_700, y: 300),
            focusedWindowFrame: nil,
            lastSelectedDisplayID: 1,
            displays: displays
        ),
        equals: 2,
        "focused-window mode falls back to the pointer without requesting access"
    )
}

func testScreenSelectionUsesGreatestWindowIntersectionAndStableTieBreak() throws {
    let displays = [
        DisplaySnapshot(id: 8, frame: DisplayFrame(minX: 0, minY: 0, width: 100, height: 100)),
        DisplaySnapshot(id: 3, frame: DisplayFrame(minX: 100, minY: 0, width: 100, height: 100)),
    ]

    try expect(
        ScreenSelection.displayID(
            containingMostOf: DisplayFrame(minX: 50, minY: 0, width: 100, height: 100),
            displays: displays
        ),
        equals: 3,
        "equal intersections use the lower stable display ID"
    )
}

func testPointerMovementGateRequiresIntentAfterPanelMove() throws {
    var gate = PointerMovementGate()
    gate.lock(at: DisplayPoint(x: 10, y: 10))

    try expect(gate.update(pointerLocation: DisplayPoint(x: 13, y: 12)), equals: false, "small movement remains locked")
    try expect(gate.update(pointerLocation: DisplayPoint(x: 16, y: 10)), equals: true, "deliberate movement unlocks hover expansion")
    try expect(gate.isUnlocked, equals: true, "gate stays unlocked after intentional movement")
}

func testPointerSamplesPublishOnlyContainmentChanges() throws {
    var reducer = PointerSampleReducer()
    let first = reducer.reduce(isInside: false, location: DisplayPoint(x: 1, y: 2))
    let entered = reducer.reduce(isInside: true, location: DisplayPoint(x: 2, y: 3))
    let movedInside = reducer.reduce(isInside: true, location: DisplayPoint(x: 3, y: 4))
    let exited = reducer.reduce(isInside: false, location: DisplayPoint(x: 4, y: 5))

    try expect(first.containmentChange, equals: nil, "initial state produces no duplicate event")
    try expect(entered.containmentChange, equals: PointerContainmentState(isInside: true, revision: 1), "entry is published")
    try expect(movedInside.containmentChange, equals: nil, "movement inside does not republish")
    try expect(exited.containmentChange, equals: PointerContainmentState(isInside: false, revision: 2), "exit is published")
}

func testHoverInteractionUsesFullCanvasOnlyWhenExpanded() throws {
    let compact = DisplayFrame(minX: 338, minY: 0, width: 292, height: 32)
    let collapsed = HoverInteraction.interactiveFrame(
        compactFrame: compact,
        expandedPanelWidth: 800,
        expandedMaximumHeight: 188,
        measuredContentHeight: 0,
        isExpanded: false
    )
    let expanded = HoverInteraction.interactiveFrame(
        compactFrame: compact,
        expandedPanelWidth: 800,
        expandedMaximumHeight: 188,
        measuredContentHeight: 120,
        isExpanded: true,
        expandedTopInset: 8
    )

    try expect(collapsed, equals: compact, "collapsed interaction matches compact controls")
    try expect(expanded.minX, equals: 0, "expanded interaction begins at canvas edge")
    try expect(expanded.width, equals: 800, "expanded interaction opens full canvas")
    try expect(expanded.minY, equals: 8, "expanded interaction retains external-display gap")
}

func testHangingNotchInteractionPassesTransparentCornersThrough() throws {
    let region = HangingNotchInteractionRegion(
        frame: DisplayFrame(minX: 0, minY: 0, width: 200, height: 120),
        cornerStyle: .bubble,
        topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
    )

    try expect(region.contains(DisplayPoint(x: 0, y: 0)), equals: false, "transparent rounded corner passes through")
    try expect(region.contains(DisplayPoint(x: 100, y: 20)), equals: true, "visible bubble accepts interaction")
}

func testPanelSynchronizationOwnsOnlyRequiredResources() throws {
    var policy = PanelSynchronizationPolicy()
    let pointer = policy.transition(to: .pointer)
    let focused = policy.transition(to: .focusedWindow)
    let all = policy.transition(to: .allDisplays)

    try expect(pointer.installed, equals: [.pointerEventMonitor], "pointer mode installs pointer monitoring")
    try expect(focused.removed, equals: [.pointerEventMonitor], "focused mode removes pointer monitoring")
    try expect(focused.installed, equals: [.focusedWindowFallbackTimer], "focused mode installs fallback timer")
    try expect(all.removed, equals: [.focusedWindowFallbackTimer], "all-displays mode needs no polling resource")
}

func testSingleInstanceLockExcludesAnotherInstance() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let lockURL = directory.appendingPathComponent("petalo.lock")
    let first = try SingleInstanceLock.acquire(at: lockURL)
    let second = try SingleInstanceLock.acquire(at: lockURL)

    try expect(first == nil, equals: false, "first instance acquires lock")
    try expect(second == nil, equals: true, "second instance is excluded")
}

func testAssistantWorkflowCapturesContextBeforeOpeningPromptAndClearsAfterDelivery() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 42)

    workflow.beginSelectedTextCapture(on: display)
    try expect(
        workflow.state,
        equals: .capturingSelectedText(display: display),
        "selected text is captured before Petalo opens a prompt"
    )

    workflow.captureSelectedText("A private selection", sourceApplication: "Notes")
    let payload = try workflow.beginDelivery(instruction: "Summarize this")
    try expect(
        payload,
        equals: AssistantPayload(
            instruction: "Summarize this",
            context: .selectedText("A private selection")
        ),
        "delivery payload keeps the instruction and selected text typed"
    )
    try expect(workflow.hasSensitiveContext, equals: true, "payload remains only while delivery is active")

    workflow.completeDelivery(.manualCompletionRequired)
    try expect(
        workflow.state,
        equals: .manualCompletion,
        "manual completion retains the payload until the user copies each required item"
    )
    try expect(
        workflow.manualCompletionPayload,
        equals: payload,
        "manual completion exposes the same typed payload without a combined pasteboard item"
    )
    try expect(workflow.hasSensitiveContext, equals: true, "manual completion keeps payload only while its panel is active")
    workflow.finishManualCompletion()
    try expect(workflow.state, equals: .idle, "manual completion finishes explicitly")
    try expect(workflow.hasSensitiveContext, equals: false, "finishing manual completion clears sensitive state")
}

func testAssistantWorkflowClearsSensitiveContextOnCancellationAndFailure() throws {
    var workflow = ContextualAssistantWorkflow()
    workflow.beginSelectedTextCapture(on: AssistantInvocationDisplay(id: 7))
    workflow.captureSelectedText("Sensitive", sourceApplication: "Mail")
    workflow.cancel()
    try expect(workflow.state, equals: .idle, "cancellation returns to idle")
    try expect(workflow.hasSensitiveContext, equals: false, "cancellation clears selected text")

    workflow.beginRegionSelection(on: AssistantInvocationDisplay(id: 7))
    workflow.captureFailed(.screenRecordingDenied)
    try expect(
        workflow.state,
        equals: .failed(.screenRecordingDenied),
        "permission failures are represented without a prompt"
    )
    try expect(workflow.hasSensitiveContext, equals: false, "failure clears any sensitive payload")
}

func testAssistantWorkflowCapturesRegionBeforePromptAndTypesItsImagePayload() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 11)
    let image = AssistantImagePayload(data: Data([0x89, 0x50, 0x4E, 0x47]))

    workflow.beginRegionSelection(on: display)
    try expect(
        workflow.state,
        equals: .selectingRegion(display: display),
        "region capture waits for an explicit selection before showing a prompt"
    )
    workflow.captureRegion(image)
    try expect(
        workflow.promptDraft?.context,
        equals: .capturedImage(image),
        "captured image remains a typed in-memory prompt context"
    )
    let payload = try workflow.beginDelivery(instruction: "Describe this")
    try expect(
        payload.context,
        equals: .capturedImage(image),
        "region submission cannot become an untyped text-only handoff"
    )
    workflow.cancel()
    try expect(workflow.hasSensitiveContext, equals: false, "region cancellation clears image bytes")
}

func testRegionSelectionNormalizesAndClampsToItsInvocationDisplay() throws {
    let display = DisplaySnapshot(
        id: 3,
        frame: DisplayFrame(minX: 100, minY: 50, width: 400, height: 200)
    )

    let region = ScreenRegionSelection.normalizedRectangle(
        start: DisplayPoint(x: 120, y: 75),
        end: DisplayPoint(x: 900, y: -100),
        on: display
    )
    try expect(
        region,
        equals: NormalizedScreenRegion(
            displayID: 3,
            x: 0.05,
            y: 0,
            width: 0.95,
            height: 0.125
        ),
        "a drag remains clamped to the display that owns its overlay"
    )
    try expect(
        ScreenRegionSelection.normalizedRectangle(
            start: DisplayPoint(x: 99, y: 75),
            end: DisplayPoint(x: 180, y: 100),
            on: display
        ),
        equals: nil,
        "a drag cannot begin on another display"
    )
}

func testNormalizedRegionSanitizationCannotEscapeItsDisplay() throws {
    let untrusted = NormalizedScreenRegion(
        displayID: 3,
        x: 0.9,
        y: -0.3,
        width: 0.9,
        height: 0.9
    )
    try expect(
        untrusted.clampedToDisplay(),
        equals: NormalizedScreenRegion(
            displayID: 3,
            x: 0.9,
            y: 0,
            width: 1 - 0.9,
            height: 0.9
        ),
        "untrusted normalized input cannot extend a capture beyond its source display"
    )
}

func testShortcutConfigurationRejectsDuplicatesAndRestoresDefaults() throws {
    let duplicate = GlobalShortcut(keyCode: 8, modifiers: .command)
    let invalid = AssistantShortcutConfiguration(
        selectedText: duplicate,
        screenRegion: duplicate
    )
    try expect(
        invalid.validationError,
        equals: .duplicateShortcut,
        "two contextual actions cannot register the same global shortcut"
    )
    try expect(
        AssistantShortcutConfiguration.defaults.selectedText,
        equals: GlobalShortcut(keyCode: 8, modifiers: [.command, .shift]),
        "selected-text shortcut has a restorable default"
    )
    try expect(
        AssistantShortcutConfiguration.defaults.screenRegion,
        equals: GlobalShortcut(keyCode: 1, modifiers: [.command, .shift]),
        "screen-region shortcut has a restorable default"
    )
    try expect(
        AssistantShortcutConfiguration.defaults.directPrompt,
        equals: GlobalShortcut(keyCode: 0, modifiers: [.command, .shift]),
        "direct-prompt shortcut has a restorable default"
    )
    try expect(
        AssistantShortcutConfiguration.defaults.validationError == nil,
        equals: true,
        "the default configuration with three shortcuts is valid"
    )
}

/// The direct-prompt shortcut participates in duplicate detection just like the
/// other two actions — it cannot collide with selected-text or screen-region.
func testShortcutConfigurationRejectsDirectPromptDuplicate() throws {
    let shared = GlobalShortcut(keyCode: 8, modifiers: [.command, .shift])
    let duplicate = AssistantShortcutConfiguration(
        selectedText: shared,
        screenRegion: GlobalShortcut(keyCode: 1, modifiers: [.command, .shift]),
        directPrompt: shared
    )
    try expect(
        duplicate.validationError,
        equals: .duplicateShortcut,
        "direct-prompt cannot share a shortcut with selected-text"
    )

    let duplicateRegion = AssistantShortcutConfiguration(
        selectedText: GlobalShortcut(keyCode: 8, modifiers: [.command, .shift]),
        screenRegion: shared,
        directPrompt: shared
    )
    try expect(
        duplicateRegion.validationError,
        equals: .duplicateShortcut,
        "direct-prompt cannot share a shortcut with screen-region"
    )
}

func testChatGPTDeliveryPolicyAutoPastesInstalledApp() throws {
    try expect(
        ChatGPTDeliveryPolicy.result(for: .unavailable),
        equals: .failed(.destinationUnavailable),
        "an unavailable ChatGPT app fails safely"
    )
    try expect(
        ChatGPTDeliveryPolicy.result(for: .autoPaste),
        equals: .completed,
        "an installed app auto-pastes the prompt into ChatGPT"
    )
}

/// The activation schedule starts at its initial delay so a fast machine does
/// no more than one short probe before ChatGPT reports frontmost, then grows
/// geometrically so a slow launch or a stolen focus still converges, and caps
/// at the ceiling so a permanently unresponsive app does not stall forever.
func testChatGPTHandoffTimingActivationScheduleGrowsGeometricallyAndCaps() throws {
    let timing = ChatGPTHandoffTiming.activation

    try expect(
        timing.delay(forAttempt: 0),
        equals: 100_000_000,
        "activation starts at the 100ms initial delay so a fast machine wastes no time"
    )
    try expect(
        timing.delay(forAttempt: 1),
        equals: 200_000_000,
        "activation doubles on the first retry (200ms)"
    )
    try expect(
        timing.delay(forAttempt: 2),
        equals: 400_000_000,
        "activation doubles again on the second retry (400ms)"
    )
    try expect(
        timing.delay(forAttempt: 3),
        equals: 800_000_000,
        "activation reaches the 800ms ceiling on the third retry"
    )
    try expect(
        timing.delay(forAttempt: 4),
        equals: 800_000_000,
        "activation stays at the ceiling for all further retries"
    )
}

/// The schedule returns nil once attempts are exhausted so the caller can give
/// up and report a delivery failure rather than spinning forever.
func testChatGPTHandoffTimingReturnsNilAfterMaxAttempts() throws {
    let timing = ChatGPTHandoffTiming.activation
    let lastValid = timing.maxAttempts - 1

    try expect(
        timing.delay(forAttempt: lastValid) != nil,
        equals: true,
        "the last valid attempt still produces a delay"
    )
    try expect(
        timing.delay(forAttempt: timing.maxAttempts),
        equals: nil as UInt64?,
        "the schedule is exhausted at maxAttempts and signals the caller to give up"
    )
    try expect(
        timing.delay(forAttempt: -1),
        equals: nil as UInt64?,
        "a negative attempt index is rejected as out of range"
    )
}

/// The recovery schedule is short (3 attempts, lower ceiling) because it only
/// needs to re-verify focus before a keystroke that is about to fire, not wait
/// out a cold app launch. This keeps the handoff resilient without adding
/// noticeable latency on a healthy machine.
func testChatGPTHandoffTimingRecoveryScheduleIsShortAndCapsLower() throws {
    let timing = ChatGPTHandoffTiming.recovery

    try expect(
        timing.maxAttempts,
        equals: 3,
        "recovery gives up quickly (3 attempts) because it only re-verifies an imminent keystroke"
    )
    try expect(
        timing.delay(forAttempt: 0),
        equals: 80_000_000,
        "recovery starts at 80ms so a healthy machine barely notices the probe"
    )
    try expect(
        timing.delay(forAttempt: 2),
        equals: 320_000_000,
        "recovery caps at 320ms (below the 400ms ceiling) on its final attempt"
    )
    try expect(
        timing.delay(forAttempt: 3),
        equals: nil as UInt64?,
        "recovery is exhausted after 3 attempts"
    )
}

/// A custom schedule honours the exact parameters passed in, so the app-layer
/// delivery code is free to tune the schedule without changing the policy type.
func testChatGPTHandoffTimingCustomScheduleHonoursParameters() throws {
    let timing = ChatGPTHandoffTiming(
        initialDelayNs: 50_000_000,
        maxDelayNs: 200_000_000,
        backoffFactor: 4.0,
        maxAttempts: 2
    )

    try expect(
        timing.delay(forAttempt: 0),
        equals: 50_000_000,
        "custom schedule uses the given initial delay"
    )
    try expect(
        timing.delay(forAttempt: 1),
        equals: 200_000_000,
        "custom schedule applies its own backoff factor (50ms * 4 = 200ms, already at ceiling)"
    )
    try expect(
        timing.delay(forAttempt: 2),
        equals: nil as UInt64?,
        "custom schedule is exhausted at its own maxAttempts"
    )
}

/// The handoff plan must write the clipboard as the very last step before each
/// paste. A clipboard manager that auto-restores the prior clipboard contents
/// after detecting a programmatic change (Maccy, Paste, Raycast, …) can
/// replace the prompt between the write and the paste if any delay or focus
/// re-check separates them. The write and the paste are both synchronous on
/// the main actor with no `await` between them, so the manager's async
/// notification handler cannot fire before the paste reads the clipboard.
///
/// This test guards that invariant: every `writeClipboard` step must be
/// immediately followed by a `paste` step, with no `verifyFrontmost`,
/// `waitNanoseconds`, or `newConversation` in between.
func testHandoffPlanWritesClipboardImmediatelyBeforeEachPaste() throws {
    let textPayload = AssistantPayload(
        instruction: "Summarize this",
        context: .selectedText("A private selection")
    )
    try assertWriteImmediatelyBeforePaste(
        in: ChatGPTHandoffPlan.textSteps(for: textPayload),
        flow: "text handoff"
    )

    let directPayload = AssistantPayload(
        instruction: "What is the time?",
        context: .none
    )
    try assertWriteImmediatelyBeforePaste(
        in: ChatGPTHandoffPlan.textSteps(for: directPayload),
        flow: "direct-prompt handoff"
    )

    let imagePayload = AssistantPayload(
        instruction: "Describe this image",
        context: .capturedImage(AssistantImagePayload(data: Data([0x89, 0x50])))
    )
    try assertWriteImmediatelyBeforePaste(
        in: ChatGPTHandoffPlan.imageThenTextSteps(for: imagePayload),
        flow: "image-then-text handoff"
    )
}

/// An image-only handoff (empty instruction) must not paste an empty text
/// step: it writes the image, pastes it, and sends Return — no second
/// clipboard write of an empty prompt. Pasting empty text into ChatGPT's
/// compose field after the image is at best a no-op and at worst disrupts the
/// attachment, so the text steps are omitted entirely when the instruction is
/// blank. The write→paste invariant is still honoured for the image step, and
/// the plan still ends with sendReturn so the image is actually sent.
func testHandoffPlanImageOnlyOmitsTextPasteWhenInstructionIsEmpty() throws {
    let image = AssistantImagePayload(data: Data([0x89, 0x50, 0x4E, 0x47]))
    let payload = AssistantPayload(instruction: "", context: .capturedImage(image))
    let steps = ChatGPTHandoffPlan.imageThenTextSteps(for: payload)

    // No text clipboard write may appear: the only writeClipboard step is the
    // image copy.
    for step in steps {
        if case .writeClipboard(.copyPrompt) = step {
            throw TestFailure.expectation(
                "image-only handoff must not include a text clipboard step, got \(step)"
            )
        }
    }
    // The write→paste invariant still holds for whatever writes remain.
    try assertWriteImmediatelyBeforePaste(in: steps, flow: "image-only handoff")
    guard steps.last == .sendReturn else {
        throw TestFailure.expectation("image-only handoff should end with sendReturn, got \(String(describing: steps.last))")
    }
    // Exactly one image clipboard write.
    let imageWriteCount = steps.reduce(0) { count, step in
        if case .writeClipboard(.copyImage) = step { return count + 1 }
        return count
    }
    try expect(imageWriteCount, equals: 1, "image-only handoff writes the image exactly once")
}

/// After Cmd+N opens a new conversation, the plan must wait long enough for
/// ChatGPT to actually open the conversation and focus its compose field
/// before the next keystroke. Too short and the paste lands in the previously
/// open conversation — the user's prompt is appended to an existing thread
/// instead of starting a fresh one. This guards a minimum settle window
/// (>= 1 second) after every newConversation step in both the text and image
/// plans.
func testHandoffPlanWaitsForNewConversationToSettle() throws {
    let textPayload = AssistantPayload(instruction: "Summarize this", context: .selectedText("sel"))
    let imagePayload = AssistantPayload(
        instruction: "Describe this",
        context: .capturedImage(AssistantImagePayload(data: Data([0x01])))
    )
    let plans: [(steps: [ChatGPTHandoffPlan.Step], flow: String)] = [
        (ChatGPTHandoffPlan.textSteps(for: textPayload), "text handoff"),
        (ChatGPTHandoffPlan.imageThenTextSteps(for: imagePayload), "image handoff"),
    ]
    for plan in plans {
        for index in plan.steps.indices {
            guard plan.steps[index] == .newConversation else { continue }
            let next = index + 1
            guard next < plan.steps.count,
                  case .waitNanoseconds(let nanoseconds) = plan.steps[next] else {
                throw TestFailure.expectation(
                    "\(plan.flow): newConversation at \(index) must be followed by a wait"
                )
            }
            guard nanoseconds >= 1_000_000_000 else {
                throw TestFailure.expectation(
                    "\(plan.flow): wait after newConversation is \(nanoseconds)ns, must be >= 1s so ChatGPT opens the new conversation before the paste"
                )
            }
        }
    }
}

/// Asserts that every `writeClipboard` step in `steps` is immediately followed
/// by a `paste` step. The gap between a write and its paste must contain no
/// `verifyFrontmost`, `waitNanoseconds`, or `newConversation` — those are the
/// async steps that give a clipboard manager time to restore the prior
/// clipboard contents before the paste reads them.
private func assertWriteImmediatelyBeforePaste(
    in steps: [ChatGPTHandoffPlan.Step],
    flow: String
) throws {
    for index in steps.indices {
        guard case .writeClipboard = steps[index] else { continue }
        let pasteIndex = index + 1
        guard pasteIndex < steps.count else {
            throw TestFailure.expectation(
                "\(flow): writeClipboard at \(index) is the last step — expected paste to follow"
            )
        }
        guard case .paste = steps[pasteIndex] else {
            throw TestFailure.expectation(
                "\(flow): writeClipboard at \(index) must be immediately followed by paste, got \(steps[pasteIndex])"
            )
        }
    }
}

func testManualCompletionUsesSeparatePromptAndImageClipboardSteps() throws {
    let image = AssistantImagePayload(data: Data([0x01, 0x02]))
    let payload = AssistantPayload(
        instruction: "Describe this image",
        context: .capturedImage(image)
    )
    try expect(
        ManualCompletionPlan.steps(for: payload),
        equals: [
            .copyPrompt("Describe this image"),
            .copyImage(image),
        ],
        "manual image completion uses separate pasteboard steps instead of alternate item representations"
    )
}

/// An empty/whitespace instruction is terminal: the captured draft is cleared
/// so an adapter can never retain a previously captured selection after the
/// user submits nothing. This guards the PRD's "clears all sensitive state
/// after ... failure" contract on the submission path.
func testAssistantWorkflowRejectsEmptyInstructionAsTerminalFailure() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 1)
    workflow.beginSelectedTextCapture(on: display)
    workflow.captureSelectedText("A real selection", sourceApplication: "Notes")
    try expect(workflow.hasSensitiveContext, equals: true, "a captured draft exists while prompting")

    do {
        _ = try workflow.beginDelivery(instruction: "   ")
        throw TestFailure.expectation("an empty instruction should not begin delivery")
    } catch AssistantWorkflowFailure.emptyInstruction {
        // expected terminal failure
    }
    try expect(workflow.state, equals: .failed(.emptyInstruction), "an empty instruction is a terminal failure")
    try expect(workflow.hasSensitiveContext, equals: false, "an empty instruction clears the captured draft")
}

/// A captured image is a complete prompt on its own — the user may send it
/// with no typed instruction. Unlike a selected-text draft (where an empty
/// instruction leaves nothing to say), an image payload is meaningful without
/// text, so `beginDelivery` must accept an empty instruction and produce a
/// payload whose instruction is empty and whose context is the captured image.
/// This is the workflow contract behind sending a screenshot to ChatGPT with
/// no accompanying text.
func testAssistantWorkflowAllowsEmptyInstructionForCapturedImage() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 3)
    workflow.beginRegionSelection(on: display)
    let image = AssistantImagePayload(data: Data([0x89, 0x50, 0x4E, 0x47]))
    workflow.captureRegion(image)
    let draft = AssistantPromptDraft(display: display, context: .capturedImage(image), sourceApplication: nil)
    try expect(workflow.state, equals: .prompting(draft), "region capture enters prompting with an image draft")

    let payload = try workflow.beginDelivery(instruction: "")
    try expect(payload.instruction, equals: "", "an image-only handoff carries an empty instruction")
    try expect(payload.context, equals: .capturedImage(image), "an image-only handoff keeps the captured image")
    try expect(workflow.state, equals: .delivering, "image-only submission enters delivering")
    try expect(workflow.hasSensitiveContext, equals: true, "payload is held during image-only delivery")
}

/// A delivery attempted without a captured prompt cannot synthesize a payload;
/// it must throw without mutating state so a misused adapter cannot ship an
/// untyped or empty handoff.
func testAssistantWorkflowBeginDeliveryIsNoOpOutsidePromptingState() throws {
    var workflow = ContextualAssistantWorkflow()
    do {
        _ = try workflow.beginDelivery(instruction: "anything")
        throw TestFailure.expectation("delivery should not begin without a captured prompt")
    } catch AssistantWorkflowFailure.deliveryFailed {
        // expected defensive failure
    }
    try expect(workflow.state, equals: .idle, "an out-of-state delivery attempt does not mutate state")
    try expect(workflow.hasSensitiveContext, equals: false, "no payload is created by an out-of-state delivery")
}

/// A second invocation while the first delivery is still in flight must not
/// silently overwrite the `.delivering` state. Without this guard, the old
/// delivery's background keystrokes (Cmd+N, Cmd+V, Return) continue firing
/// while the new capture proceeds, causing the old payload to race the new
/// one into ChatGPT. The guard forces the caller to `abandonDelivery()`
/// first, which is the coordinator's signal to cancel the old delivery Task.
func testAssistantWorkflowRejectsNewCaptureWhileDelivering() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 1)

    // Drive to .delivering via the selected-text path.
    workflow.beginSelectedTextCapture(on: display)
    workflow.captureSelectedText("First selection", sourceApplication: nil)
    _ = try workflow.beginDelivery(instruction: "First instruction")
    try expect(workflow.state, equals: .delivering, "precondition: workflow is delivering")

    // A second selected-text capture is rejected — state stays .delivering.
    workflow.beginSelectedTextCapture(on: display)
    try expect(workflow.state, equals: .delivering, "a second capture cannot overwrite a delivering state")

    // A second region selection is also rejected.
    workflow.beginRegionSelection(on: display)
    try expect(workflow.state, equals: .delivering, "a second region selection cannot overwrite a delivering state")
}

/// `abandonDelivery` is the explicit way out of `.delivering` when the
/// coordinator has cancelled the in-flight Task. It clears the payload and
/// returns to `.idle`, freeing the state machine to accept a new capture.
/// After abandonment, `beginSelectedTextCapture` works again, which is the
/// contract the coordinator relies on to start a fresh capture cycle.
func testAssistantWorkflowAbandonDeliveryFreesStateForNewCapture() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 1)

    workflow.beginSelectedTextCapture(on: display)
    workflow.captureSelectedText("First selection", sourceApplication: nil)
    _ = try workflow.beginDelivery(instruction: "First instruction")
    try expect(workflow.hasSensitiveContext, equals: true, "precondition: delivering retains payload")

    workflow.abandonDelivery()
    try expect(workflow.state, equals: .idle, "abandonDelivery returns to idle")
    try expect(workflow.hasSensitiveContext, equals: false, "abandonDelivery clears the in-flight payload")

    // After abandonment, a new capture cycle works end-to-end.
    workflow.beginSelectedTextCapture(on: display)
    try expect(workflow.state, equals: .capturingSelectedText(display: display), "new capture is accepted after abandonment")
    workflow.captureSelectedText("Second selection", sourceApplication: nil)
    let payload = try workflow.beginDelivery(instruction: "Second instruction")
    try expect(payload.instruction, equals: "Second instruction", "the second payload carries the new instruction")
    try expect(
        payload.context,
        equals: .selectedText("Second selection"),
        "the second payload carries the new selection, not the abandoned one"
    )
}

/// `abandonDelivery` is a no-op outside `.delivering` so a stray call from
/// the coordinator cannot accidentally clear a draft or clobber another state.
func testAssistantWorkflowAbandonDeliveryIsNoOpOutsideDelivering() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 1)

    // From .idle — no-op.
    workflow.abandonDelivery()
    try expect(workflow.state, equals: .idle, "abandonDelivery is a no-op from idle")

    // From .prompting — no-op, draft is preserved.
    workflow.beginSelectedTextCapture(on: display)
    workflow.captureSelectedText("A draft", sourceApplication: nil)
    workflow.abandonDelivery()
    try expect(workflow.state, equals: .prompting(workflow.promptDraft!), "abandonDelivery does not clobber a prompting draft")
    try expect(workflow.hasSensitiveContext, equals: true, "the draft is still alive after a stray abandonDelivery")
}

/// Success and destination-failure outcomes both clear the in-flight payload.
/// Together with the existing cancellation test, this completes the PRD's
/// "clears all sensitive state after success, cancellation, or failure".
func testAssistantWorkflowClearsPayloadOnCompletedAndFailedDelivery() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 1)

    workflow.beginSelectedTextCapture(on: display)
    workflow.captureSelectedText("Secret", sourceApplication: nil)
    _ = try workflow.beginDelivery(instruction: "Go")
    try expect(workflow.hasSensitiveContext, equals: true, "delivering retains the in-flight payload")
    workflow.completeDelivery(.completed)
    try expect(workflow.state, equals: .idle, "a completed delivery returns to idle")
    try expect(workflow.hasSensitiveContext, equals: false, "a completed delivery clears the payload")

    workflow.beginSelectedTextCapture(on: display)
    workflow.captureSelectedText("Secret again", sourceApplication: nil)
    _ = try workflow.beginDelivery(instruction: "Go")
    workflow.completeDelivery(.failed(.destinationUnavailable))
    try expect(workflow.state, equals: .failed(.destinationUnavailable), "a destination failure is surfaced")
    try expect(workflow.hasSensitiveContext, equals: false, "a failed delivery clears the payload")
}

/// Whitespace-only selected text and empty image bytes are unsupported inputs
/// that must fail safely without retaining a payload — the PRD's "unsupported
/// apps ... produce actionable, non-destructive errors" contract at the model.
func testAssistantWorkflowRejectsEmptySelectionAndEmptyImageBytes() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 1)

    workflow.beginSelectedTextCapture(on: display)
    workflow.captureSelectedText("   \n  ", sourceApplication: nil)
    try expect(workflow.state, equals: .failed(.selectedTextUnavailable), "whitespace-only selected text is unsupported")
    try expect(workflow.hasSensitiveContext, equals: false, "a rejected selection leaves no payload")

    workflow.beginRegionSelection(on: display)
    workflow.captureRegion(AssistantImagePayload(data: Data()))
    try expect(workflow.state, equals: .failed(.captureFailed), "empty image bytes are rejected")
    try expect(workflow.hasSensitiveContext, equals: false, "a rejected capture leaves no payload")
}

/// `dismissFailure` is the only way out of the `.failed` state other than
/// starting a new action, and sensitive drafts/payloads are exposed only in
/// their owning states (`.prompting` and `.manualCompletion`).
func testAssistantWorkflowDismissesFailureAndOnlyExposesContextInOwningStates() throws {
    var workflow = ContextualAssistantWorkflow()
    let display = AssistantInvocationDisplay(id: 1)

    workflow.dismissFailure()
    try expect(workflow.state, equals: .idle, "dismissFailure is a no-op outside the failed state")
    try expect(workflow.promptDraft == nil, equals: true, "no draft is exposed while idle")
    try expect(workflow.manualCompletionPayload == nil, equals: true, "no payload is exposed while idle")

    workflow.beginSelectedTextCapture(on: display)
    try expect(workflow.promptDraft == nil, equals: true, "no draft is exposed before capture completes")

    workflow.captureFailed(.accessibilityDenied)
    try expect(workflow.state, equals: .failed(.accessibilityDenied), "a permission failure is represented")
    workflow.dismissFailure()
    try expect(workflow.state, equals: .idle, "dismissFailure returns to idle")

    workflow.beginSelectedTextCapture(on: display)
    workflow.captureSelectedText("Private", sourceApplication: nil)
    _ = try workflow.beginDelivery(instruction: "Go")
    workflow.completeDelivery(.manualCompletionRequired)
    try expect(workflow.manualCompletionPayload == nil, equals: false, "manual completion exposes its payload")
    workflow.finishManualCompletion()
    try expect(workflow.manualCompletionPayload == nil, equals: true, "finishing manual completion withdraws the payload")
}

/// A `manualCompletionRequired` result arriving without an in-flight payload
/// (a misused adapter) must fail safely rather than park the user in a
/// manual-completion panel with nothing to copy.
func testAssistantWorkflowManualCompletionWithoutInFlightPayloadFailsSafely() throws {
    var workflow = ContextualAssistantWorkflow()
    workflow.completeDelivery(.manualCompletionRequired)
    try expect(workflow.state, equals: .failed(.deliveryFailed), "manual completion without a payload cannot hold a stuck state")
    try expect(workflow.hasSensitiveContext, equals: false, "no payload was ever created")
}

/// A shortcut with no modifier is unsafe to register globally and must be
/// rejected; disabling one or more shortcuts is a valid, intentional state.
func testShortcutConfigurationRejectsMissingModifierAndAcceptsDisabledShortcuts() throws {
    let noModifier = GlobalShortcut(keyCode: 8, modifiers: [])
    let missingModifier = AssistantShortcutConfiguration(
        selectedText: noModifier,
        screenRegion: GlobalShortcut(keyCode: 1, modifiers: .command)
    )
    try expect(missingModifier.validationError, equals: .missingModifier, "a shortcut without a modifier is rejected")

    let missingModifierDirect = AssistantShortcutConfiguration(
        selectedText: GlobalShortcut(keyCode: 8, modifiers: .command),
        screenRegion: GlobalShortcut(keyCode: 1, modifiers: .command),
        directPrompt: noModifier
    )
    try expect(missingModifierDirect.validationError, equals: .missingModifier, "direct-prompt without a modifier is rejected")

    let allDisabled = AssistantShortcutConfiguration(selectedText: nil, screenRegion: nil, directPrompt: nil)
    try expect(allDisabled.validationError == nil, equals: true, "all shortcuts disabled is valid")

    let oneDisabled = AssistantShortcutConfiguration(
        selectedText: nil,
        screenRegion: GlobalShortcut(keyCode: 1, modifiers: [.command, .shift]),
        directPrompt: GlobalShortcut(keyCode: 0, modifiers: [.command, .shift])
    )
    try expect(oneDisabled.validationError == nil, equals: true, "one disabled and two valid shortcuts is valid")

    try expect(AssistantShortcutConfiguration.defaults.validationError == nil, equals: true, "the default configuration is valid")
}

/// A zero-area drag yields no capture rectangle, and `hasArea` is the gate a
/// capture adapter uses to reject degenerate and out-of-display regions before
/// touching a platform capture API.
func testRegionSelectionRejectsDegenerateDragsAndReportsArea() throws {
    let display = DisplaySnapshot(id: 3, frame: DisplayFrame(minX: 0, minY: 0, width: 400, height: 200))

    try expect(
        ScreenRegionSelection.normalizedRectangle(
            start: DisplayPoint(x: 100, y: 50),
            end: DisplayPoint(x: 100, y: 50),
            on: display
        ) == nil,
        equals: true,
        "a zero-area drag produces no capture rectangle"
    )

    try expect(
        NormalizedScreenRegion(displayID: 3, x: 0.1, y: 0.1, width: 0.5, height: 0.5).hasArea,
        equals: true,
        "a region inside the display has area"
    )
    try expect(
        NormalizedScreenRegion(displayID: 3, x: 0.1, y: 0.1, width: 0, height: 0.5).hasArea,
        equals: false,
        "a zero-width region has no area"
    )
    try expect(
        NormalizedScreenRegion(displayID: 3, x: 0.5, y: 0.5, width: 0.6, height: 0.5).hasArea,
        equals: false,
        "a region extending past the display edge has no valid area"
    )
}

/// Coordinate data is untrusted; non-finite values must collapse to the unit
/// square's origin so a capture adapter never passes NaN/infinity to
/// ScreenCaptureKit. PRD: "Coordinate transforms and Retina scale are untrusted
/// inputs and must be clamped and validated."
func testNormalizedRegionSanitizationClampsNonFiniteInputToZero() throws {
    let nonFinite = NormalizedScreenRegion(
        displayID: 3,
        x: .nan,
        y: -.infinity,
        width: .nan,
        height: .infinity
    )
    let clamped = nonFinite.clampedToDisplay()
    try expect(clamped.x, equals: 0, "non-finite x clamps to zero")
    try expect(clamped.y, equals: 0, "non-finite y clamps to zero")
    try expect(clamped.width, equals: 0, "non-finite width clamps to zero")
    try expect(clamped.height, equals: 0, "non-finite height clamps to zero")
    try expect(clamped.hasArea, equals: false, "non-finite input cannot become a capture")
}

/// The live drag renders as a rounded-rect liquid-glass lens, so the overlay
/// needs the same drag geometry as a clamped rounded rectangle. The radius
/// clamps to half the shorter side (a tiny drag never carries an oversized
/// radius), and degenerate/non-finite drags return nil — the same contract
/// `normalizedRectangle` uses to gate a capture.
func testRoundedSelectionRectClampsRadiusAndRejectsDegenerateDrags() throws {
    let normal = ScreenRegionSelection.roundedSelectionRect(
        start: CGPoint(x: 100, y: 50),
        end: CGPoint(x: 300, y: 150),
        cornerRadius: 12
    )
    try expect(
        normal?.rect,
        equals: CGRect(x: 100, y: 50, width: 200, height: 100),
        "a normal drag produces a min/max rectangle"
    )
    try expect(normal?.cornerRadius, equals: 12, "a small radius passes through")

    let clamped = ScreenRegionSelection.roundedSelectionRect(
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 40, y: 200),
        cornerRadius: 30
    )
    try expect(
        clamped?.rect,
        equals: CGRect(x: 0, y: 0, width: 40, height: 200),
        "a tall drag keeps its rectangle"
    )
    try expect(clamped?.cornerRadius, equals: 20, "radius clamps to half the shorter side")

    let negativeRadius = ScreenRegionSelection.roundedSelectionRect(
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 100, y: 100),
        cornerRadius: -8
    )
    try expect(negativeRadius?.cornerRadius, equals: 0, "a negative radius clamps to zero")

    try expect(
        ScreenRegionSelection.roundedSelectionRect(
            start: CGPoint(x: 50, y: 50),
            end: CGPoint(x: 50, y: 50),
            cornerRadius: 10
        ) == nil,
        equals: true,
        "a zero-area drag produces no rounded rect"
    )
    try expect(
        ScreenRegionSelection.roundedSelectionRect(
            start: CGPoint(x: CGFloat.nan, y: 0),
            end: CGPoint(x: 100, y: 100),
            cornerRadius: 10
        ) == nil,
        equals: true,
        "non-finite start returns nil"
    )
}

/// Refraction scales with the selection's smaller dimension so a small drag
/// carries subtle edge lensing and a large one gets the full aberration. The
/// ratio is the min dimension over the reference size, clamped to [0, 1].
func testRefractionScalesProportionallyToSelectionSize() throws {
    let full = GlassRefractionScale.scale(
        minDimension: 280,
        referenceSize: 280,
        maxInnerAmount: -150,
        maxInnerHeight: 44,
        maxOuterAmount: -40,
        maxOuterHeight: 18
    )
    try expect(full.innerAmount, equals: -150, "a selection at the reference size gets full inner refraction")
    try expect(full.innerHeight, equals: 44, "inner height is full at reference size")
    try expect(full.outerAmount, equals: -40, "outer amount is full at reference size")
    try expect(full.outerHeight, equals: 18, "outer height is full at reference size")

    let half = GlassRefractionScale.scale(
        minDimension: 140,
        referenceSize: 280,
        maxInnerAmount: -150,
        maxInnerHeight: 44,
        maxOuterAmount: -40,
        maxOuterHeight: 18
    )
    try expect(half.innerAmount, equals: -75, "a half-size selection gets half the inner refraction")
    try expect(half.innerHeight, equals: 22, "inner height halves with the ratio")
    try expect(half.outerAmount, equals: -20, "outer refraction scales by the same ratio")

    let clamped = GlassRefractionScale.scale(
        minDimension: 600,
        referenceSize: 280,
        maxInnerAmount: -150,
        maxInnerHeight: 44,
        maxOuterAmount: -40,
        maxOuterHeight: 18
    )
    try expect(clamped.innerAmount, equals: -150, "a selection larger than the reference is clamped to full")
    try expect(clamped.outerAmount, equals: -40, "outer is clamped, not exceeded")

    let tiny = GlassRefractionScale.scale(
        minDimension: 14,
        referenceSize: 280,
        maxInnerAmount: -150,
        maxInnerHeight: 44,
        maxOuterAmount: -40,
        maxOuterHeight: 18
    )
    try expect(tiny.innerAmount, equals: -7.5, "a tiny selection carries proportionally little refraction")

    let zero = GlassRefractionScale.scale(
        minDimension: 0,
        referenceSize: 280,
        maxInnerAmount: -150,
        maxInnerHeight: 44,
        maxOuterAmount: -40,
        maxOuterHeight: 18
    )
    try expect(zero.innerAmount, equals: 0, "a degenerate selection has no refraction")
    try expect(zero.outerAmount, equals: 0, "degenerate outer is zero too")

    let noReference = GlassRefractionScale.scale(
        minDimension: 100,
        referenceSize: 0,
        maxInnerAmount: -150,
        maxInnerHeight: 44,
        maxOuterAmount: -40,
        maxOuterHeight: 18
    )
    try expect(noReference.innerAmount, equals: 0, "a zero reference size yields no refraction")
}

/// The selected-text branch of the manual-completion plan produces a single
/// combined prompt step (instruction plus labeled selection), in contrast to
/// the image branch's separate prompt/image steps. This documents the typed
/// payload contract for the text-only handoff.
func testManualCompletionCombinesInstructionAndSelectedTextIntoOnePromptStep() throws {
    let payload = AssistantPayload(
        instruction: "Summarize this",
        context: .selectedText("A private selection")
    )
    try expect(
        ManualCompletionPlan.steps(for: payload),
        equals: [.copyPrompt("Summarize this\n\nSelected text:\nA private selection")],
        "a selected-text handoff is a single combined prompt step, not a multipart paste"
    )
}

func testCombinedPromptTextMergesInstructionAndSelection() throws {
    let payload = AssistantPayload(
        instruction: "Summarize this",
        context: .selectedText("A private selection")
    )
    try expect(
        ManualCompletionPlan.combinedPromptText(for: payload),
        equals: "Summarize this\n\nSelected text:\nA private selection",
        "combined prompt text merges instruction and selected text for automatic paste"
    )
}

func testCombinedPromptTextForImageIsInstructionOnly() throws {
    let image = AssistantImagePayload(data: Data([0x01, 0x02]))
    let payload = AssistantPayload(
        instruction: "Describe this image",
        context: .capturedImage(image)
    )
    try expect(
        ManualCompletionPlan.combinedPromptText(for: payload),
        equals: "Describe this image",
        "combined prompt text for an image payload is the instruction only"
    )
}

// MARK: - Unified prompt surface layout

/// On a notched display the prompt surface stays attached to the top edge: the
/// content drops straight from the notch bar, and the silhouette keeps the
/// hanging-notch bottom radius rather than the bubble's 38pt. The bottom
/// padding is tighter (4pt) than the pill's (8pt) since the notch is attached.
func testPromptSurfaceAttachesToTopOnNotchDisplay() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .text
    )

    try expect(surface.presentation, equals: .notch, "notch prompt inherits notch presentation")
    try expect(surface.cornerStyle, equals: .hangingNotch, "notch prompt keeps hanging-notch silhouette")
    try expect(surface.contentWidth, equals: PromptSurfaceLayout.bubbleWidth, "notch prompt uses bubble width")
    try expect(surface.contentTopOffset, equals: 32, "notch content begins right below the safe-area bar (no expanded top gap)")
    try expect(surface.bottomPadding, equals: PromptSurfaceLayout.notchBottomPadding, "notch uses tighter bottom padding")
    try expect(
        surface.panelHeight,
        equals: 32 + PromptSurfaceLayout.textContentHeight + PromptSurfaceLayout.notchBottomPadding,
        "notch panel height is bar + text content + notch bottom padding"
    )
    try expect(
        surface.bottomCornerRadius,
        equals: HangingNotchMetrics.bottomCornerRadius,
        "notch prompt keeps the standard notch bottom radius, not the bubble's 38pt"
    )
}

/// The prompt content width clamps to the panel width on a narrow display.
func testPromptSurfaceClampsContentWidthToPanel() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 400,
        topGap: 0,
        contentMode: .text
    )

    try expect(surface.contentWidth, equals: 400, "content width clamps to the panel width when narrower than the bubble")
}

/// On an external (notchless) display the prompt is a floating bubble matching
/// the standalone prompt panel's width and corner radius exactly. The content
/// starts right below the bar with no extra gap (the old pillExpandedTopGap
/// margin is gone — the header occupies the bar).
func testPromptSurfaceFloatsAsBubbleOnExternalDisplay() throws {
    // pill: topGap=4, barHeight=16
    let surface = PromptSurfaceLayout.layout(
        presentation: .pill,
        barHeight: 16,
        panelWidth: 480,
        topGap: 4,
        contentMode: .text
    )

    try expect(surface.presentation, equals: .pill, "external prompt inherits pill presentation")
    try expect(surface.cornerStyle, equals: .bubble, "external prompt is a rounded bubble")
    try expect(surface.contentWidth, equals: PromptSurfaceLayout.bubbleWidth, "external prompt matches the standalone bubble width")
    try expect(
        surface.bottomCornerRadius,
        equals: PromptSurfaceLayout.bubbleBottomCornerRadius,
        "external prompt matches the standalone bubble corner radius (38pt)"
    )
    // contentTopOffset = topGap + pillExpandedTopGap + barHeight = 4 + 20 + 16 = 40
    try expect(surface.contentTopOffset, equals: 40, "external content begins below the bar with expanded top gap for header breathing room")
    try expect(surface.bottomPadding, equals: PromptSurfaceLayout.pillBottomPadding, "pill uses standard bottom padding")
}

/// When expanded, the notch adopts a larger, softer bottom corner radius
/// matching the external pill's bubble — so the open card reads as a natural
/// bubble hanging from the screen edge. The compact bar keeps the tight notch
/// radius (20pt) so the collapsed silhouette still hugs the hardware cutout.
func testPromptSurfaceNotchUsesLargerBubbleRadiusWhenExpanded() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .text
    )

    try expect(
        surface.bottomCornerRadius,
        equals: HangingNotchMetrics.bottomCornerRadius,
        "notch keeps the tight notch radius for the collapsed bar"
    )
    try expect(
        surface.expandedBottomCornerRadius,
        equals: PromptSurfaceLayout.bubbleBottomCornerRadius,
        "expanded notch matches the external pill bubble radius for a natural bubble profile"
    )
}

/// The pill is already a bubble in both states, so its expanded radius matches
/// its collapsed radius — no state-dependent swap.
func testPromptSurfacePillKeepsBubbleRadiusInBothStates() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .pill,
        barHeight: 16,
        panelWidth: 480,
        topGap: 4,
        contentMode: .text
    )

    try expect(
        surface.bottomCornerRadius,
        equals: PromptSurfaceLayout.bubbleBottomCornerRadius,
        "pill uses the bubble radius when collapsed"
    )
    try expect(
        surface.expandedBottomCornerRadius,
        equals: PromptSurfaceLayout.bubbleBottomCornerRadius,
        "pill keeps the same bubble radius when expanded"
    )
}

/// When expanded, the notch's concave top shoulder radius grows to match the
/// larger bottom bubble radius, so the open card's curves are symmetric — a
/// natural bubble profile edge to edge. The compact bar keeps the tight
/// shoulder radius (14pt) so the collapsed silhouette still hugs the hardware
/// cutout.
func testPromptSurfaceNotchUsesLargerTopShoulderRadiusWhenExpanded() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .text
    )

    try expect(
        surface.expandedTopShoulderRadius,
        equals: PromptSurfaceLayout.expandedNotchTopShoulderRadius,
        "expanded notch top shoulder uses the larger radius"
    )
    try expect(
        surface.expandedTopShoulderRadius,
        equals: surface.expandedBottomCornerRadius,
        "expanded notch top and bottom radii match for a symmetric bubble profile"
    )
}

/// The pill is a detached bubble (no concave shoulders), so its top shoulder
/// radius is zero — the bubble path ignores it entirely in both states.
func testPromptSurfacePillTopShoulderRadiusIsZero() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .pill,
        barHeight: 16,
        panelWidth: 480,
        topGap: 4,
        contentMode: .text
    )

    try expect(
        surface.expandedTopShoulderRadius,
        equals: 0,
        "pill has no concave top shoulder; expanded top shoulder radius is zero"
    )
}

/// The image prompt surface is taller than the text surface by exactly the
/// image-vs-text content delta.
func testPromptSurfaceImageContentIsTallerThanText() throws {
    let text = PromptSurfaceLayout.layout(
        presentation: .pill,
        barHeight: 16,
        panelWidth: 480,
        topGap: 4,
        contentMode: .text
    )
    let image = PromptSurfaceLayout.layout(
        presentation: .pill,
        barHeight: 16,
        panelWidth: 480,
        topGap: 4,
        contentMode: .image
    )

    try expect(
        image.panelHeight - text.panelHeight,
        equals: PromptSurfaceLayout.imageContentHeight - PromptSurfaceLayout.textContentHeight,
        "image prompt grows by exactly the image-vs-text content delta"
    )
}

/// A selected-text draft keeps the prompt header as "Ask ChatGPT" and moves the
/// context into a preview container below it (analogous to the image preview).
/// The surface therefore reserves a distinct, intermediate height: taller than
/// the no-context text surface (room for the preview) and shorter than the
/// image surface. This locks the layout contract for the new preview container.
func testPromptSurfaceSelectedTextContentIsTallerThanTextAndShorterThanImage() throws {
    let text = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .text
    )
    let selected = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .selectedText
    )
    let image = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .image
    )

    try expect(
        selected.panelHeight > text.panelHeight,
        equals: true,
        "selected-text surface reserves room for the preview above the editor"
    )
    try expect(
        selected.panelHeight < image.panelHeight,
        equals: true,
        "selected-text preview is shorter than the image preview"
    )
    try expect(
        selected.panelHeight - text.panelHeight,
        equals: PromptSurfaceLayout.selectedTextContentHeight - PromptSurfaceLayout.textContentHeight,
        "selected-text surface grows by exactly the selected-text-vs-text content delta"
    )
}

/// The base layout stores its panel height as `basePanelHeight` so the
/// dynamic text-editor-height adjustment always recomputes from the same
/// fixed origin — never accumulating growth across repeated calls.
func testPromptSurfaceBasePanelHeightMatchesPanelHeight() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .text
    )

    try expect(surface.basePanelHeight, equals: surface.panelHeight, "base panel height matches the factory panel height")
}

/// When the text editor's measured intrinsic height exceeds the base editor
/// height, the panel grows by exactly the delta so the bubble fits the taller
/// text without clipping.
func testPromptSurfaceGrowsWithTextEditorHeight() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .text
    )
    let measured = PromptSurfaceLayout.baseTextEditorHeight + 30

    let grown = surface.withTextEditorHeight(measured)

    try expect(grown.panelHeight, equals: surface.panelHeight + 30, "panel grows by the editor height delta")
    try expect(grown.basePanelHeight, equals: surface.basePanelHeight, "base panel height is unchanged")
}

/// When the measured editor height is at or below the base, the panel stays at
/// its base height — the internal spacer absorbs the slack. This also covers
/// the shrink-back case: deleting text returns the panel to its base.
func testPromptSurfaceStaysAtBaseWhenEditorDoesNotExceedBase() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .text
    )

    // Below base → no growth.
    try expect(
        surface.withTextEditorHeight(20).panelHeight,
        equals: surface.panelHeight,
        "editor shorter than base keeps the panel at base height"
    )
    // Exactly base → no growth.
    try expect(
        surface.withTextEditorHeight(PromptSurfaceLayout.baseTextEditorHeight).panelHeight,
        equals: surface.panelHeight,
        "editor at exactly base keeps the panel at base height"
    )
}

/// After growing, calling `withTextEditorHeight` with a smaller value shrinks
/// the panel back to the correct height — the adjustment is always computed
/// from `basePanelHeight`, never from the current (possibly grown) height.
func testPromptSurfaceShrinksBackFromGrownHeight() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .text
    )
    let grown = surface.withTextEditorHeight(PromptSurfaceLayout.baseTextEditorHeight + 50)
    try expect(grown.panelHeight, equals: surface.panelHeight + 50, "panel grew by 50")

    // Shrink back to base.
    let shrunk = grown.withTextEditorHeight(20)
    try expect(shrunk.panelHeight, equals: surface.panelHeight, "panel shrinks back to base when editor returns below base")
}

/// The editor height is capped at `maxTextEditorHeight` so the panel never
/// grows unbounded.
func testPromptSurfaceCapsEditorHeightAtMaximum() throws {
    let surface = PromptSurfaceLayout.layout(
        presentation: .notch,
        barHeight: 32,
        panelWidth: 480,
        topGap: 0,
        contentMode: .text
    )
    let huge = surface.withTextEditorHeight(10_000)

    let expectedExtra = PromptSurfaceLayout.maxTextEditorHeight - PromptSurfaceLayout.baseTextEditorHeight
    try expect(huge.panelHeight, equals: surface.panelHeight + expectedExtra, "panel caps growth at max editor height")
}

// MARK: - Direct (no-context) prompt workflow

/// A direct prompt submitted from idle (the hover path) builds a `.none`
/// payload and clears sensitive context after delivery completes.
func testDirectPromptFromIdleDeliversNoneContextAndClearsAfterDelivery() throws {
    var workflow = ContextualAssistantWorkflow()
    try expect(workflow.state, equals: .idle, "workflow starts idle for a hover-initiated prompt")

    let payload = try workflow.beginDirectDelivery(instruction: "What is the capital of France?")
    try expect(payload.instruction, equals: "What is the capital of France?", "direct payload keeps the instruction")
    try expect(payload.context, equals: .none, "direct payload has no captured context")
    try expect(workflow.state, equals: .delivering, "direct submission enters delivering state")
    try expect(workflow.hasSensitiveContext, equals: true, "payload is held during delivery")

    workflow.completeDelivery(.completed)
    try expect(workflow.state, equals: .idle, "completed direct delivery returns to idle")
    try expect(workflow.hasSensitiveContext, equals: false, "completed delivery clears the payload")
}

/// An empty direct instruction is a terminal failure, just like the shortcut
/// path — no stale state survives.
func testDirectPromptRejectsEmptyInstruction() throws {
    var workflow = ContextualAssistantWorkflow()
    do {
        _ = try workflow.beginDirectDelivery(instruction: "   ")
        throw TestFailure.expectation("empty direct instruction should fail")
    } catch let failure as AssistantWorkflowFailure {
        try expect(failure, equals: .emptyInstruction, "empty direct instruction reports emptyInstruction")
    }
    try expect(workflow.state, equals: .failed(.emptyInstruction), "empty direct instruction is terminal")
    try expect(workflow.hasSensitiveContext, equals: false, "empty direct instruction clears state")
}

/// `beginDirectDelivery` is only valid from idle; it throws otherwise.
func testDirectDeliveryIsInvalidOutsideIdle() throws {
    var workflow = ContextualAssistantWorkflow()
    workflow.beginSelectedTextCapture(on: AssistantInvocationDisplay(id: 1))
    workflow.captureSelectedText("sel", sourceApplication: nil)
    // Now in .prompting — direct delivery must not silently shadow the draft.
    do {
        _ = try workflow.beginDirectDelivery(instruction: "x")
        throw TestFailure.expectation("direct delivery should fail outside idle")
    } catch let failure as AssistantWorkflowFailure {
        try expect(failure, equals: .deliveryFailed, "direct delivery outside idle reports deliveryFailed")
    } catch {
        throw TestFailure.expectation("direct delivery outside idle should throw AssistantWorkflowFailure")
    }
}

/// A no-context payload pastes only the instruction (no selection suffix).
func testCombinedPromptTextForNoneContextIsInstructionOnly() throws {
    let payload = AssistantPayload(instruction: "Summarize the meeting", context: .none)
    try expect(
        ManualCompletionPlan.combinedPromptText(for: payload),
        equals: "Summarize the meeting",
        "no-context combined prompt text is the instruction only"
    )
    try expect(
        ManualCompletionPlan.steps(for: payload),
        equals: [.copyPrompt("Summarize the meeting")],
        "no-context manual plan has a single copy-prompt step"
    )
}

// MARK: - Selected text preview snippet

/// The selected-text preview container shows a compact snippet of the pasted
/// selection so the user can see the added context at a glance. The raw
/// selection may span many lines with ragged indentation; the snippet
/// collapses every run of whitespace (spaces, tabs, newlines) into a single
/// space and trims the ends, so the preview never shows line breaks or gaps.
/// SwiftUI's `lineLimit` + `truncationMode` adds the trailing ellipsis
/// visually; this function only normalizes the raw text.
func testSelectedTextPreviewSnippetCollapsesWhitespaceIntoSingleSpaces() throws {
    try expect(
        SelectedTextPreview.snippet(from: "hello world"),
        equals: "hello world",
        "single spaces are preserved"
    )
    try expect(
        SelectedTextPreview.snippet(from: "  hello   world  "),
        equals: "hello world",
        "leading, trailing, and repeated spaces collapse to single spaces"
    )
    try expect(
        SelectedTextPreview.snippet(from: "line1\nline2\nline3"),
        equals: "line1 line2 line3",
        "newlines collapse into single spaces"
    )
    try expect(
        SelectedTextPreview.snippet(from: "tab\tthere"),
        equals: "tab there",
        "tabs collapse into single spaces"
    )
    try expect(
        SelectedTextPreview.snippet(from: "   "),
        equals: "",
        "whitespace-only selection collapses to an empty snippet"
    )
    try expect(
        SelectedTextPreview.snippet(from: ""),
        equals: "",
        "empty selection collapses to an empty snippet"
    )
}

// MARK: - Prompt key policy

/// The prompt panel must be actively made key — not just permitted to become
/// key — whenever the surface is expanded, so the text field's cursor is
/// blinking and ready to type on click, hover, and shortcut paths alike.
/// When collapsed the panel stays non-key to preserve transparent-corner
/// click-through. This guards the contract that opening the surface always
/// focuses the text field regardless of the trigger.
func testPromptKeyPolicyMakesPanelKeyOnlyWhileExpanded() throws {
    try expect(
        PromptKeyPolicy.shouldMakeKey(isExpanded: true),
        equals: true,
        "expanded surface makes the panel key so the text field receives keyboard input immediately"
    )
    try expect(
        PromptKeyPolicy.shouldMakeKey(isExpanded: false),
        equals: false,
        "collapsed surface keeps the panel non-key to preserve transparent-corner click-through"
    )
}

/// The jelly wobble deforms the *render* path only. Its resting shape (phase
/// 0 and 1) must be byte-for-byte the rigid silhouette, and amplitude 0 must
/// be a no-op for any phase, so the effect is free until it is asked to play.
func testWobbleRestsOnRigidSilhouetteAtEndpoints() throws {
    let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
    let rigid = HangingNotchGeometry.path(
        in: rect, style: .hangingNotch,
        topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
    )

    for phase in [CGFloat(0), CGFloat(1)] {
        let wobbled = HangingNotchGeometry.wobbledPath(
            in: rect, style: .hangingNotch,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius,
            phase: phase, amplitude: 5
        )
        try expect(
            wobbled.boundingBox, equals: rigid.boundingBox,
            "wobble at phase \(phase) rests on the rigid silhouette (no recoil)"
        )
    }

    for phase in [CGFloat(0), CGFloat(0.25), CGFloat(0.5), CGFloat(0.75), CGFloat(1)] {
        let wobbled = HangingNotchGeometry.wobbledPath(
            in: rect, style: .hangingNotch,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius,
            phase: phase, amplitude: 0
        )
        try expect(
            wobbled.boundingBox, equals: rigid.boundingBox,
            "amplitude 0 is a no-op at phase \(phase)"
        )
    }
}

/// The wobble pulls the bottom edge *upward* (into the bubble) and never past
/// the resting bounds — so it clips nowhere. At the first crest the recoil
/// equals `amplitude`; the bounding box shrinks by that amount. The bubble
/// silhouette recoils the same way.
func testWobbleRecoilsBottomEdgeUpwardAtCrest() throws {
    let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
    let amplitude: CGFloat = 5
    let crest = HangingNotchGeometry.wobbledPath(
        in: rect, style: .hangingNotch,
        topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius,
        phase: 0.25, amplitude: amplitude
    ).boundingBox
    try expect(
        crest.height < rect.height,
        equals: true,
        "wobble crest shrinks the silhouette height (bottom recoils upward)"
    )
    try expect(
        abs(crest.height - (rect.height - amplitude)) < 1,
        equals: true,
        "first crest recoils by ~amplitude points"
    )
    try expect(
        crest.minY, equals: rect.minY,
        "wobble is one-sided: the top edge stays pinned (no downward extension)"
    )

    let bubbleCrest = HangingNotchGeometry.wobbledPath(
        in: rect, style: .bubble,
        topShoulderRadius: 0,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius,
        phase: 0.25, amplitude: amplitude
    ).boundingBox
    try expect(
        abs(bubbleCrest.height - (rect.height - amplitude)) < 1,
        equals: true,
        "bubble silhouette recoils by ~amplitude at the first crest"
    )
}

/// The wobble is render-only: hit testing keeps using the rigid silhouette, so
/// a point at the resting bottom edge stays "inside" even while the render
/// path is recoiled — the tappable area never jiggles.
func testWobbleDoesNotAffectHitTesting() throws {
    let width: CGFloat = 400
    let height: CGFloat = 200
    let bottomCenter = DisplayPoint(x: width / 2, y: height - 1)
    try expect(
        HangingNotchGeometry.contains(
            bottomCenter,
            width: width, height: height,
            style: .hangingNotch,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        ),
        equals: true,
        "bottom-center is inside the rigid silhouette"
    )
    // The wobbled path recoils, so the same point is outside the *render*
    // path at the crest — confirming render and hit-test diverge on purpose.
    let crestPath = HangingNotchGeometry.wobbledPath(
        in: CGRect(x: 0, y: 0, width: width, height: height),
        style: .hangingNotch,
        topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
        bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius,
        phase: 0.25, amplitude: 5
    ).boundingBox
    try expect(
        crestPath.maxY < height - 1,
        equals: true,
        "render path's bottom recoils above the still-tapped bottom-center point"
    )
}

/// A jelly drag spring converges to the target and, being underdamped,
/// overshoots it at least once on the way (the wobble). Integrated for many
/// small fixed steps so the result is deterministic and frame-rate-shaped.
func testDragSpringJellyConvergesAndOvershoots() throws {
    let spring = DragSpring.jelly
    var pos = CGPoint(x: 0, y: 0)
    var vel = CGVector(dx: 0, dy: 0)
    let target = CGPoint(x: 100, y: 0)
    let dt: TimeInterval = 1.0 / 90.0
    var overshot = false

    for _ in 0..<600 {
        let next = spring.step(position: pos, velocity: vel, toward: target, dt: dt)
        pos = next.position
        vel = next.velocity
        if pos.x > target.x { overshot = true }
    }

    try expect(
        abs(pos.x - target.x) < 0.5,
        equals: true,
        "jelly spring converges to the target within a hair"
    )
    try expect(
        abs(vel.dx) < 1,
        equals: true,
        "jelly spring settles to ~zero velocity"
    )
    try expect(
        overshot,
        equals: true,
        "jelly spring is underdamped: it overshoots the target at least once (the wobble)"
    )
}

/// The jelly spring trails a moving target (the rubber-band lag): after a
/// target jump, the rendered position is still behind it for the first step,
/// confirming the render lags the cursor instead of snapping to it.
func testDragSpringJellyLagsMovingTarget() throws {
    let spring = DragSpring.jelly
    var pos = CGPoint(x: 0, y: 0)
    var vel = CGVector(dx: 0, dy: 0)
    let target = CGPoint(x: 100, y: 0)
    let dt: TimeInterval = 1.0 / 90.0

    // One step from rest: the spring accelerates toward the target but has
    // not reached it (the lag). A rigid snap would put pos == target here.
    let next = spring.step(position: pos, velocity: vel, toward: target, dt: dt)
    pos = next.position
    vel = next.velocity

    try expect(
        pos.x > 0,
        equals: true,
        "jelly spring starts moving toward the target on the first step"
    )
    try expect(
        pos.x < target.x,
        equals: true,
        "jelly spring lags the target after one step (rubber-band, not a snap)"
    )
}

/// A zero-stiffness spring with zero velocity is a no-op: the position never
/// moves. This is the guard the overlay's Reduce-Motion path relies on if it
/// ever routes through the spring — the rigid render stays pinned to the
/// cursor.
func testDragSpringRigidIsNoOp() throws {
    let rigid = DragSpring(stiffness: 0, damping: 0)
    var pos = CGPoint(x: 42, y: 7)
    var vel = CGVector(dx: 0, dy: 0)
    let target = CGPoint(x: 1_000, y: -1_000)
    for _ in 0..<10 {
        let next = rigid.step(position: pos, velocity: vel, toward: target, dt: 1.0 / 90.0)
        pos = next.position
        vel = next.velocity
    }
    try expect(pos, equals: CGPoint(x: 42, y: 7), "zero-stiffness spring with zero velocity never moves")
    try expect(vel, equals: CGVector(dx: 0, dy: 0), "zero-stiffness spring accumulates no velocity")
}

/// The jelly squash envelope must return to identity at both endpoints —
/// otherwise SwiftUI's `keyframeAnimator` leaves the notch at the final
/// keyframe's scale after the animation, shrinking the resting silhouette
/// (the "no cubre el 100% de la altura del notch" regression).
func testJellySquashEnvelopeRestsOnIdentityAtEndpoints() throws {
    let duration = 0.42
    let start = JellySquashEnvelope.scaleOffset(phase: 0, duration: duration)
    try expect(start.dx, equals: 0, "jelly scale is identity (dx) at phase 0")
    try expect(start.dy, equals: 0, "jelly scale is identity (dy) at phase 0")

    let end = JellySquashEnvelope.scaleOffset(phase: duration, duration: duration)
    try expect(end.dx, equals: 0, "jelly scale is identity (dx) at phase duration")
    try expect(end.dy, equals: 0, "jelly scale is identity (dy) at phase duration — no persistent shrink")

    // Past the window the envelope stays identity too.
    let past = JellySquashEnvelope.scaleOffset(phase: duration + 1, duration: duration)
    try expect(past.dx, equals: 0, "jelly scale is identity past the window (dx)")
    try expect(past.dy, equals: 0, "jelly scale is identity past the window (dy)")
}

/// The envelope is nonzero mid-animation (the jelly exists), and at the
/// first crest it stretches tall (dy > 0) while narrowing (dx < 0) — the
/// volume-preserving squash & stretch read. dx/dy tracks the coupling.
func testJellySquashEnvelopeStretchesAtFirstCrest() throws {
    let duration = 0.42
    let crestPhase = 1.0 / 6.0   // first crest of sin(3π·phase) at phase = π/(2·angular)
    let crest = JellySquashEnvelope.scaleOffset(phase: crestPhase, duration: duration)
    try expect(crest.dy > 0.04, equals: true, "jelly stretches tall (dy > 0) at the first crest")
    try expect(crest.dx < -0.02, equals: true, "jelly narrows (dx < 0) at the first crest")
    let ratio = -crest.dx / crest.dy
    try expect(
        abs(ratio - JellySquashEnvelope.widthCoupling) < 0.01,
        equals: true,
        "dx/dy tracks the width coupling (volume-preserving)"
    )
}

/// The outside scrim holds at full strength while the wave is still crossing
/// the selection, then dissolves to exactly zero — so the overlay "lifts"
/// instead of being yanked, and the final frame carries no dim at all.
func testReleaseRippleDimFadeHoldsThenClearsToZero() throws {
    try expect(ReleaseRippleEnvelope.dimFade(phase: 0), equals: 1, "the dim is full at the release instant")
    try expect(
        ReleaseRippleEnvelope.dimFade(
            phase: ReleaseRippleEnvelope.duration * ReleaseRippleEnvelope.dimHoldFraction
        ),
        equals: 1,
        "the dim holds while the wave crosses"
    )
    try expect(
        ReleaseRippleEnvelope.dimFade(phase: ReleaseRippleEnvelope.duration),
        equals: 0,
        "the dim is exactly gone when the ripple ends"
    )
    try expect(
        ReleaseRippleEnvelope.dimFade(phase: ReleaseRippleEnvelope.duration + 1),
        equals: 0,
        "the dim stays gone past the ripple"
    )
    let mid = ReleaseRippleEnvelope.dimFade(phase: ReleaseRippleEnvelope.duration * 0.85)
    try expect(mid > 0, equals: true, "the dim is still partially present mid-fade")
    try expect(mid < 1, equals: true, "the dim has started dissolving mid-fade")
}

/// The hairline flash is the shutter "click": a fast pulse that is back to
/// the resting stroke well before the ripple ends, so it never competes with
/// the dim dissolve.
func testReleaseRippleHairlineFlashPeaksEarlyAndReturnsToZero() throws {
    try expect(ReleaseRippleEnvelope.hairlineFlash(phase: 0), equals: 0, "no flash at the release instant")
    try expect(
        ReleaseRippleEnvelope.hairlineFlash(phase: ReleaseRippleEnvelope.flashDuration),
        equals: 0,
        "the flash is spent at the end of its window"
    )
    try expect(
        ReleaseRippleEnvelope.hairlineFlash(phase: ReleaseRippleEnvelope.duration),
        equals: 0,
        "the flash is long gone when the ripple ends"
    )
    let peak = ReleaseRippleEnvelope.hairlineFlash(phase: ReleaseRippleEnvelope.flashDuration / 2)
    try expect(abs(peak - 1) < 0.0001, equals: true, "the flash peaks halfway through its window")
    try expect(
        ReleaseRippleEnvelope.flashDuration < ReleaseRippleEnvelope.duration,
        equals: true,
        "the flash finishes before the ripple does"
    )
}

/// The release pulse scales the rendered selection about its center. The
/// center must not move — otherwise the lens, the dim cutout and the hairline
/// would drift off the region the user actually outlined — and the radius
/// re-clamps so the squashed rect keeps a legal rounded shape.
func testScaledSelectionRectKeepsCenterAndClampsRadius() throws {
    let base = RoundedSelectionRect(
        rect: CGRect(x: 100, y: 50, width: 200, height: 100),
        cornerRadius: 28
    )
    let squashed = ScreenRegionSelection.scaled(base, by: CGSize(width: 0.9, height: 1.1))
    try expect(squashed.rect.midX, equals: base.rect.midX, "the squash keeps the center X")
    try expect(squashed.rect.midY, equals: base.rect.midY, "the squash keeps the center Y")
    try expect(squashed.rect.width, equals: 180, "the squash scales the width")
    try expect(
        abs(squashed.rect.height - 110) < 0.0001,
        equals: true,
        "the squash scales the height"
    )

    // A radius larger than half the shorter side must re-clamp after scaling.
    let thin = RoundedSelectionRect(
        rect: CGRect(x: 0, y: 0, width: 40, height: 200),
        cornerRadius: 20
    )
    let shrunk = ScreenRegionSelection.scaled(thin, by: CGSize(width: 0.5, height: 1))
    try expect(shrunk.cornerRadius, equals: 10, "the radius re-clamps to half the shorter side")

    // Degenerate scales are a no-op rather than a collapsed rectangle.
    let degenerate = ScreenRegionSelection.scaled(base, by: CGSize(width: 0, height: CGFloat.nan))
    try expect(degenerate, equals: base, "a degenerate scale leaves the rect untouched")
}

/// The overlay tracks the drag in AppKit's bottom-left space but hands the
/// release location to a SwiftUI-hosted shader, which reads `position`
/// top-left. Without the flip the wave would set out from the selection's
/// opposite edge. Flipping twice is the identity, which is the cheap way to
/// pin the conversion in both directions.
func testVerticalFlipMovesReleasePointIntoTopLeftSpaceAndBack() throws {
    let height: CGFloat = 300
    let point = CGPoint(x: 42, y: 200)
    let flipped = ScreenRegionSelection.flippedVertically(point, inHeight: height)
    try expect(flipped, equals: CGPoint(x: 42, y: 100), "the release point mirrors about the midline")
    try expect(
        ScreenRegionSelection.flippedVertically(flipped, inHeight: height),
        equals: point,
        "flipping twice is the identity"
    )
    // Releasing on the bottom edge must land on the top edge, not off-view.
    try expect(
        ScreenRegionSelection.flippedVertically(CGPoint(x: 10, y: 0), inHeight: height),
        equals: CGPoint(x: 10, y: 300),
        "the bottom edge maps to the top edge"
    )
}

/// The Metal ripple is switched off the instant the overlay is torn down, so
/// the wave has to be at rest by then — a shader disabled while it still
/// carries displacement snaps the frame straight on its final frame.
///
/// The wave is far too lightly damped to manage that on its own now (that is
/// the price of a visible counter-swing), so `window(phase:)` lands it. Being a
/// factor on the whole wave, it lands *every* point at once — including the far
/// edge the wavefront has only just reached, which the old decay-only tuning
/// could only excuse by pointing at the dissolve.
func testReleaseRippleShaderIsSpentBeforeTheOverlayIsTornDown() throws {
    for distance in [0.0, 200.0, 900.0, 2_000.0] {
        try expect(
            ReleaseRippleShader.displacementBound(
                phase: ReleaseRippleEnvelope.duration,
                distance: distance,
                amplitude: fullAmplitude,
                speed: fullSpeed
            ),
            equals: 0,
            "the wave is at rest everywhere on the last frame before teardown"
        )
        try expect(
            ReleaseRippleShader.displacement(phase: 0, distance: distance, amplitude: fullAmplitude, speed: fullSpeed),
            equals: 0,
            "and at rest everywhere on the frame the captured still takes over"
        )
    }
    // Mid-ripple the wave must actually be doing something, or the shader is
    // just an expensive no-op. Probed clear of the impact point, which is now
    // deliberately a pivot rather than the crest.
    let alive = ReleaseRippleShader.displacementBound(
        phase: 0.08,
        distance: 120,
        amplitude: fullAmplitude,
        speed: fullSpeed
    )
    try expect(alive > 4, equals: true, "the wave carries real displacement mid-ripple")
}

/// The field is radial, so it is singular at the release point: anything within
/// a displacement's reach of it gets dragged through it, folding the silhouette
/// and creasing the pixels. The taper bounds the displacement by the distance to
/// the origin, which keeps the warp injective — no fold, no tear.
///
/// At the old amplitude this never showed. At an amplitude you can actually see,
/// removing the taper puts a spike through the corner the user just released.
func testReleaseRippleNeverDragsASampleThroughTheImpactPoint() throws {
    for step in 0...60 {
        let phase = ReleaseRippleEnvelope.duration * Double(step) / 60
        for distance in stride(from: 0.0, through: 300.0, by: 5.0) {
            try expect(
                abs(ReleaseRippleShader.displacement(
                    phase: phase,
                    distance: distance,
                    amplitude: fullAmplitude,
                    speed: fullSpeed
                )) <= distance,
                equals: true,
                "no point is displaced past the impact it is moving around"
            )
        }
    }
    try expect(
        ReleaseRippleShader.displacement(phase: 0.08, distance: 0, amplitude: fullAmplitude, speed: fullSpeed),
        equals: 0,
        "the impact point itself is the pivot, and stays put"
    )
}

/// Amplitude for a selection large enough to get the wave at full strength —
/// what every probe below is measured at.
let fullAmplitude = ReleaseRippleShader.amplitude(
    forMinDimension: ReleaseRippleShader.amplitudeReference
)

/// Propagation speed at the reference diagonal — the calibration point for
/// `speed(forDiagonal:)`. Every probe below is measured at this speed, so the
/// existing assertions carry over unchanged.
let fullSpeed = ReleaseRippleShader.speed(forDiagonal: ReleaseRippleShader.speedReference)

/// Peak displacement at `distance` over the whole life of the ripple.
func peakDisplacement(atDistance distance: Double) -> Double {
    var peak = 0.0
    for step in 0...900 {
        let phase = ReleaseRippleEnvelope.duration * Double(step) / 900
        peak = max(peak, abs(ReleaseRippleShader.displacement(
            phase: phase,
            distance: distance,
            amplitude: fullAmplitude,
            speed: fullSpeed
        )))
    }
    return peak
}

/// The wave is a single expansion, not a vibrating plate. Two properties:
///
/// **One throw.** The surface bulges out once as the wavefront passes and
/// settles back. The counter-swing is a small fraction of the first throw —
/// enough to keep the settle from looking like a hard stop, but not enough
/// to read as a second wave. The old tuning at `frequency 26` produced 3–4
/// visible oscillations; now `frequency 8` fits exactly one cycle in the
/// window.
///
/// **Born at the cursor.** The displacement is strongest at the release and
/// weaker further out. This is not automatic: the wave's damping runs in each
/// point's own local time, so every point gets the same shape when the front
/// arrives, and the global window is the only thing that can tell them apart.
/// A symmetric window gets this exactly backwards — it peaks around the time
/// the front reaches the far edge, so the far edge swings *harder* than the
/// impact.
func testReleaseRippleIsOneExpansionAndFadesFromTheCursorOutward() throws {
    // Walked just clear of the impact point: that is the pivot of the radial
    // field, so the swing is read from the surface around it.
    let atImpact = fullAmplitude * 1.5
    var swings: [Double] = []
    var previous = 0.0
    var beforeThat = 0.0
    for step in 1...900 {
        let phase = ReleaseRippleEnvelope.duration * Double(step) / 900
        let value = ReleaseRippleShader.displacement(
            phase: phase,
            distance: atImpact,
            amplitude: fullAmplitude,
            speed: fullSpeed
        )
        if step > 2,
           (previous > beforeThat && previous >= value) || (previous < beforeThat && previous <= value) {
            swings.append(previous)
        }
        beforeThat = previous
        previous = value
    }
    // Exactly one expansion: a peak (the throw out) and a tiny counter-swing
    // (the settle). No third turnaround — the surface does not oscillate.
    // Sub-point swings from the window's numerical tail are filtered out: they
    // are invisible and not part of the wave's shape.
    let visibleSwings = swings.filter { abs($0) > 0.5 }
    try expect(visibleSwings.count == 2, equals: true, "the wave turns around exactly twice: one throw, one settle")
    let firstThrow = visibleSwings[0]
    let counterSwing = visibleSwings[1]
    try expect(abs(firstThrow) > 12, equals: true, "the first throw is plainly visible, not a nudge")
    try expect(
        firstThrow * counterSwing < 0,
        equals: true,
        "the surface comes back through its rest shape the other way"
    )
    try expect(
        abs(counterSwing) < abs(firstThrow) * 0.25,
        equals: true,
        "the counter-swing is a quiet settle, not a second wave"
    )

    // Born under the cursor: monotonically weaker as the wave spreads.
    let atCursor = peakDisplacement(atDistance: atImpact)
    let midway = peakDisplacement(atDistance: 400)
    let farEdge = peakDisplacement(atDistance: 800)
    try expect(atCursor > midway, equals: true, "the wave is strongest where it was born")
    try expect(midway > farEdge, equals: true, "and keeps fading as it spreads")

    try expect(
        ReleaseRippleShader.wavefrontReach(phase: 0, speed: fullSpeed), equals: 0,
        "the wavefront starts at the release point"
    )
}

/// A typical drag is 640x420 — 765 pt corner to corner.
let typicalSelectionDiagonal: Double = 765

/// The wave that makes a large drag slosh convincingly is measured in tens of
/// points, and a small drag is only a hundred or so points across: applied flat
/// it would fold a button-sized selection in half. The throw is therefore a
/// fraction of the shape, not a fixed distance — the same rule the drag lens
/// already follows for its refraction.
func testReleaseRippleAmplitudeScalesWithTheSelectionSize() throws {
    let large = ReleaseRippleShader.amplitude(
        forMinDimension: ReleaseRippleShader.amplitudeReference * 3
    )
    try expect(
        large, equals: ReleaseRippleShader.maximumAmplitude,
        "past the reference the throw stops growing"
    )
    let small = ReleaseRippleShader.amplitude(forMinDimension: 120)
    try expect(small < large, equals: true, "a small selection is thrown less")
    // Proportional below the reference: the deformation stays the same
    // *fraction* of the shape all the way down.
    let ratio = small / 120
    let atReference = ReleaseRippleShader.amplitude(
        forMinDimension: ReleaseRippleShader.amplitudeReference
    ) / ReleaseRippleShader.amplitudeReference
    try expect(
        abs(ratio - atReference) < 0.0001,
        equals: true,
        "small selections keep the same proportions as one at the reference"
    )
    // And that fraction has to leave the shape recognisable.
    try expect(small < 120 * 0.25, equals: true, "the throw never approaches the selection's own size")
    try expect(
        ReleaseRippleShader.amplitude(forMinDimension: 0), equals: 0,
        "a degenerate selection has no wave"
    )
}

/// The wavefront has to cross the selection well inside the window, or the
/// far half of the border never moves before the overlay is torn down. With
/// `speed` scaling proportionally to the diagonal, this crossing time is a
/// constant fraction of the ripple's duration on every selection — the one
/// spatial property that matters for a single-expansion wave, since the
/// number of crests is no longer the design.
func testReleaseRippleWavefrontCrossesATypicalSelection() throws {
    let speed = ReleaseRippleShader.speed(forDiagonal: typicalSelectionDiagonal)
    let reach = ReleaseRippleShader.wavefrontReach(phase: ReleaseRippleEnvelope.duration, speed: speed)
    try expect(
        reach > typicalSelectionDiagonal,
        equals: true,
        "the front crosses a typical drag before the overlay is torn down"
    )
    // Crossing has to leave room for the surface to actually swing once it is
    // reached, not arrive on the last frame.
    try expect(
        typicalSelectionDiagonal / speed
            < ReleaseRippleEnvelope.duration * 0.8,
        equals: true,
        "the far corner is reached with time left to move"
    )
}

/// The wavelength and propagation speed both scale with the selection's
/// diagonal, so the wave reads the same on a button-sized drag as on a
/// full-screen one: the same number of crests travel across in the same
/// fraction of the ripple's life. Without scaling, a small selection sees the
/// wavefront flash across almost instantly — too fast to read — and a large
/// one never sees it reach the far edge at all.
///
/// `frequency` (the temporal oscillation rate at each point) stays constant:
/// only `speed` scales, which stretches the spatial pattern proportionally
/// without changing how fast any given point wobbles.
func testReleaseRippleSpeedScalesWithSelectionDiagonal() throws {
    let small = 150.0
    let large = 2_000.0

    // Speed is proportional to the diagonal — uncapped, since a larger
    // selection needs a faster front to cross it in the same time.
    let speedSmall = ReleaseRippleShader.speed(forDiagonal: small)
    let speedTypical = ReleaseRippleShader.speed(forDiagonal: typicalSelectionDiagonal)
    let speedLarge = ReleaseRippleShader.speed(forDiagonal: large)
    try expect(speedSmall < speedTypical, equals: true, "a smaller selection gets a slower wavefront")
    try expect(speedLarge > speedTypical, equals: true, "a larger selection gets a faster wavefront")
    try expect(
        abs(speedSmall / speedTypical - small / typicalSelectionDiagonal) < 0.0001,
        equals: true,
        "speed is proportional to the diagonal, not capped"
    )

    // The spatial period (wavelength) scales with the diagonal, so the same
    // number of lobes fits across any selection.
    func lobes(forDiagonal d: Double) -> Double {
        let s = ReleaseRippleShader.speed(forDiagonal: d)
        let period = 2 * Double.pi * s / ReleaseRippleShader.frequency
        return d / period
    }
    try expect(
        abs(lobes(forDiagonal: small) - lobes(forDiagonal: typicalSelectionDiagonal)) < 0.0001,
        equals: true,
        "a small selection fits the same number of crests as a typical one"
    )
    try expect(
        abs(lobes(forDiagonal: large) - lobes(forDiagonal: typicalSelectionDiagonal)) < 0.0001,
        equals: true,
        "and so does a large one"
    )

    // The wavefront reaches the far corner in the same fraction of the
    // ripple's duration on every selection.
    func crossingFraction(_ d: Double) -> Double {
        let s = ReleaseRippleShader.speed(forDiagonal: d)
        return d / s / ReleaseRippleEnvelope.duration
    }
    try expect(
        abs(crossingFraction(small) - crossingFraction(typicalSelectionDiagonal)) < 0.0001,
        equals: true,
        "the crossing time is the same fraction of the ripple on any selection"
    )
    try expect(
        abs(crossingFraction(large) - crossingFraction(typicalSelectionDiagonal)) < 0.0001,
        equals: true,
        "large and typical cross in the same fraction"
    )
    try expect(
        crossingFraction(typicalSelectionDiagonal) < 0.8,
        equals: true,
        "the far corner is reached with time to move"
    )

    // Degenerate input.
    try expect(ReleaseRippleShader.speed(forDiagonal: 0), equals: 0, "a degenerate selection has no wave")
    try expect(ReleaseRippleShader.speed(forDiagonal: .nan), equals: 0, "non-finite diagonals are rejected")
}

/// Signed distance from a point to a rounded rectangle's outline: negative
/// inside, positive outside, exactly zero on it. Every outline test below is a
/// statement about this number — "how far off the rigid shape is this point" —
/// so the six lines pay for themselves.
func roundedRectSignedDistance(_ point: CGPoint, _ rounded: RoundedSelectionRect) -> CGFloat {
    let rect = rounded.rect
    let radius = min(max(rounded.cornerRadius, 0), rect.width / 2, rect.height / 2)
    let qx = abs(point.x - rect.midX) - (rect.width / 2 - radius)
    let qy = abs(point.y - rect.midY) - (rect.height / 2 - radius)
    return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
}

/// How far the deformed outline strays from the rigid rounded rect, at its
/// worst point.
func outlineExcursion(_ points: [CGPoint], from rounded: RoundedSelectionRect) -> CGFloat {
    points.reduce(0) { max($0, abs(roundedRectSignedDistance($1, rounded))) }
}

func requireOutline(
    _ rounded: RoundedSelectionRect,
    origin: CGPoint,
    phase: TimeInterval
) throws -> [CGPoint] {
    guard let points = RippleOutline.deformedBoundary(rounded, origin: origin, phase: phase) else {
        throw TestFailure.expectation("expected an outline at phase \(phase), got nil")
    }
    return points
}

/// The house rule for every release envelope, now applied to the silhouette
/// itself. At the release instant the outline has to be the rigid rounded rect
/// *exactly*: that frame is the handoff where the captured still replaces the
/// live glass lens, and any deformation there reads as a jump.
///
/// At `duration` the claim is the same one
/// `testReleaseRippleShaderIsSpentBeforeTheOverlayIsTornDown` makes about the
/// pixels, and for the same reason — the panel is ordered out on that frame, so
/// a border still swinging would snap straight as it disappears. Both endpoints
/// are exact, not merely small, because `window(phase:)` multiplies the whole
/// wave: it does not matter how far the wavefront has got.
func testRippleOutlineRestsOnTheRoundedRectAtBothEndpoints() throws {
    let rounded = RoundedSelectionRect(
        rect: CGRect(x: 120, y: 80, width: 640, height: 420),
        cornerRadius: 28
    )
    let origin = CGPoint(x: 760, y: 500)

    let atRelease = try requireOutline(rounded, origin: origin, phase: 0)
    try expect(
        outlineExcursion(atRelease, from: rounded) < 0.0001,
        equals: true,
        "the outline is the rigid rounded rect at the release instant"
    )

    let spent = try requireOutline(rounded, origin: origin, phase: ReleaseRippleEnvelope.duration)
    try expect(
        outlineExcursion(spent, from: rounded) < 0.0001,
        equals: true,
        "the border is back on its rigid shape on the last frame before teardown"
    )
    try expect(
        ReleaseRippleEnvelope.dimFade(phase: ReleaseRippleEnvelope.duration),
        equals: 0,
        "and the surface still carrying the wavefront has dissolved to nothing"
    )
}

/// What makes this a wave and not the elastic pop that already existed: the
/// deformation *travels*. Early in the ripple the edge by the release point is
/// already wobbling while the far edge has not been reached at all and is still
/// perfectly rigid.
func testRippleOutlineDeformsNearTheReleaseBeforeTheFarEdge() throws {
    let rounded = RoundedSelectionRect(
        rect: CGRect(x: 0, y: 0, width: 900, height: 600),
        cornerRadius: 28
    )
    // Released at a corner — where the drag actually ends.
    let origin = CGPoint(x: 900, y: 600)
    let outline = try requireOutline(rounded, origin: origin, phase: 0.03)

    let moving = outline.filter { abs(roundedRectSignedDistance($0, rounded)) > 0.5 }
    let stillRigid = outline.filter { abs(roundedRectSignedDistance($0, rounded)) < 0.000001 }
    try expect(!moving.isEmpty, equals: true, "the edge by the release has started to wobble")
    try expect(
        !stillRigid.isEmpty,
        equals: true,
        "the far edge is untouched — the wavefront has not arrived yet"
    )
    // The wobble has to be on the near side, not scattered: everything moving
    // is closer to the release than everything still at rest.
    let farthestMoving = moving.map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0
    let nearestRigid = stillRigid.map { hypot($0.x - origin.x, $0.y - origin.y) }.min() ?? 0
    try expect(
        farthestMoving <= nearestRigid,
        equals: true,
        "the deformation is a ring expanding from the release, not a global pulse"
    )
}

/// The outline and the shader's pixels are driven by the same field, so the
/// hairline can never drift off the captured frame's edge — and the excursion
/// is bounded by the margin the hosting view is inflated with, which is what
/// makes that inflation sufficient rather than hopeful.
func testRippleOutlineIsVisibleAndStaysWithinTheHostingMargin() throws {
    let rounded = RoundedSelectionRect(
        rect: CGRect(x: 0, y: 0, width: 640, height: 420),
        cornerRadius: 28
    )
    let origin = CGPoint(x: 640, y: 420)

    var peak: CGFloat = 0
    var phase: TimeInterval = 0
    while phase <= ReleaseRippleEnvelope.duration {
        let outline = try requireOutline(rounded, origin: origin, phase: phase)
        peak = max(peak, outlineExcursion(outline, from: rounded))
        phase += 0.005
    }
    try expect(
        peak <= RippleOutline.margin(for: rounded.rect) + 0.0001,
        equals: true,
        "the wobble never escapes the margin the hosting view is inflated with"
    )
    // The whole point of the retune: at 5 pt on a 640 pt-wide selection this
    // was technically present and practically invisible in the app. Subtle is
    // still visible — the throw is a few percent of the shorter side, not a
    // fold — so the excursion has to clear the hairline's own width.
    try expect(peak > 14, equals: true, "the edge deformation is plainly visible")

    // The signed displacement is the shader's own wave; its envelope bounds it.
    for probe in stride(from: 0.0, through: ReleaseRippleEnvelope.duration, by: 0.01) {
        for distance in [0.0, 120.0, 700.0] {
            let signed = ReleaseRippleShader.displacement(
                phase: probe,
                distance: distance,
                amplitude: fullAmplitude,
                speed: fullSpeed
            )
            let bound = ReleaseRippleShader.displacementBound(
                phase: probe,
                distance: distance,
                amplitude: fullAmplitude,
                speed: fullSpeed
            )
            try expect(
                abs(signed) <= bound + 0.0001,
                equals: true,
                "the signed wave stays inside its own decay envelope"
            )
        }
    }
}

/// The outline is a polyline, so it has to be dense enough to read as a curve —
/// a faceted corner is worse than no wobble at all — while staying bounded on a
/// 5K-wide selection so the per-frame cost cannot run away.
func testRippleOutlineIsClosedAndDenseEnoughToReadAsACurve() throws {
    let rounded = RoundedSelectionRect(
        rect: CGRect(x: 0, y: 0, width: 640, height: 420),
        cornerRadius: 28
    )
    let outline = try requireOutline(rounded, origin: CGPoint(x: 640, y: 420), phase: 0.06)
    try expect(outline.count >= 64, equals: true, "the outline carries enough points to curve")
    var worstGap: CGFloat = 0
    for index in outline.indices {
        let next = outline[(index + 1) % outline.count]
        worstGap = max(worstGap, hypot(next.x - outline[index].x, next.y - outline[index].y))
    }
    try expect(worstGap <= 5.5, equals: true, "consecutive samples stay close enough to read smooth")

    // Implicitly closed: the last point wraps to the first without a jump.
    let wrap = hypot(
        outline[0].x - outline[outline.count - 1].x,
        outline[0].y - outline[outline.count - 1].y
    )
    try expect(wrap <= 5.5, equals: true, "the outline closes without a gap")

    // A 5K-wide drag keeps the point count bounded.
    let huge = RoundedSelectionRect(
        rect: CGRect(x: 0, y: 0, width: 5_120, height: 2_880),
        cornerRadius: 28
    )
    let hugeOutline = try requireOutline(huge, origin: .zero, phase: 0.06)
    try expect(hugeOutline.count <= 2_208, equals: true, "the sample count stays bounded")

    // Degenerate geometry has no outline at all, matching the nil contract the
    // rest of ScreenRegionSelection uses — the overlay falls back to its rigid
    // CGPath rather than stroking garbage.
    let degenerate = RoundedSelectionRect(rect: CGRect(x: 0, y: 0, width: 0, height: 0), cornerRadius: 4)
    try expect(
        RippleOutline.deformedBoundary(degenerate, origin: .zero, phase: 0.1) == nil,
        equals: true,
        "a zero-area selection has no outline"
    )
    try expect(
        RippleOutline.deformedBoundary(rounded, origin: .zero, phase: .nan) == nil,
        equals: true,
        "a non-finite phase has no outline"
    )
    try expect(
        RippleOutline.deformedBoundary(
            rounded,
            origin: CGPoint(x: CGFloat.infinity, y: 0),
            phase: 0.1
        ) == nil,
        equals: true,
        "a non-finite release point has no outline"
    )
}

/// The vertical expand/collapse spring must NOT overshoot — dampingFraction
/// >= 1.0 (critically damped or overdamped). During collapse the virtual
/// notch shrinks toward the physical hardware cutout height; an underdamped
/// spring dips below it, and because the overlay is transparent the hardware
/// notch shows through (the "se ve el Notch" glitch). The horizontal spring
/// MAY overshoot — there is wing margin on both sides, so a horizontal bounce
/// is safe and reads as the elastic "rebote" feel.
func testNotchVerticalSpringDoesNotOvershoot() throws {
    try expect(
        NotchExpandSpringSpec.vertical.overshoots,
        equals: false,
        "vertical spring must not overshoot (dampingFraction >= 1.0) to prevent the virtual notch from dipping behind the physical hardware cutout"
    )
}

func testNotchHorizontalSpringMayOvershoot() throws {
    try expect(
        NotchExpandSpringSpec.horizontal.overshoots,
        equals: true,
        "horizontal spring bounces (dampingFraction < 1.0) for the elastic rebote feel — wing margin makes a horizontal overshoot safe"
    )
}

func testNotchReduceMotionSpringMinimizesOvershoot() throws {
    try expect(
        NotchExpandSpringSpec.reduceMotion.dampingFraction >= 0.8,
        equals: true,
        "reduce-motion spring is near-critically-damped (dampingFraction >= 0.8) to honor the accessibility preference"
    )
}

/// The "Send to ChatGPT" button's exit must be the exact inverse of its
/// entry: it scales back down to the same hidden scale and fades out in
/// place, rather than sliding off the trailing edge as the panel collapses
/// (the panel's leading-offset animation would otherwise drag a still-mounted
/// button ~86pt to the right on a notched display). Entry zooms from
/// `hiddenScale` to `restingScale`; exit must therefore start at
/// `restingScale` and end at `hiddenScale`. Locks the symmetric contract that
/// the SwiftUI view implements with a single Boolean plus an asymmetric
/// `.transition`.
func testPromptButtonZoomExitIsInverseOfEntry() throws {
    let entry = PromptButtonZoom.entryScaleRange
    let exit = PromptButtonZoom.exitScaleRange

    try expect(
        PromptButtonZoom.hiddenScale < PromptButtonZoom.restingScale,
        equals: true,
        "hidden scale is smaller than resting so the exit shrinks the button"
    )
    try expect(
        exit.from,
        equals: entry.to,
        "exit starts where entry ends (resting scale)"
    )
    try expect(
        exit.to,
        equals: entry.from,
        "exit ends where entry starts (hidden scale) — the dismissal is the inverse of the entry"
    )
}

/// The collapsed pill has no camera cutout to hide, so its scrim must collapse
/// to a flat smoked tint (the user's tint opacity) instead of the flat black
/// the notch uses to hide the hardware housing. The collapsed notch keeps
/// pure black. Both states are "shapes no taller than the solid band," so the
/// distinction is driven entirely by `collapsedOpacity`: the pill passes its
/// tint, the notch passes 1.0.
func testPillCollapsedScrimIsSmokedTintNotFlatBlack() throws {
    let tint: Double = 0.22
    let barHeight: CGFloat = 16
    let solidBand = barHeight + NotchGlassStyle.solidBandOverlap

    // Collapsed pill: no camera to hide, so the scrim collapses to the flat
    // smoked tint rather than flat black.
    let collapsedPill = NotchGlassStyle.scrimStops(
        height: barHeight,
        solidBandHeight: solidBand,
        bottomOpacity: tint,
        collapsedOpacity: tint
    )
    try expect(
        collapsedPill.first?.opacity,
        equals: tint,
        "collapsed pill scrim is smoked tint at the top"
    )
    try expect(
        collapsedPill.last?.opacity,
        equals: tint,
        "collapsed pill scrim is smoked tint at the bottom"
    )

    // Collapsed notch: the camera band must stay pure black.
    let collapsedNotch = NotchGlassStyle.scrimStops(
        height: barHeight,
        solidBandHeight: solidBand,
        bottomOpacity: tint,
        collapsedOpacity: 1.0
    )
    try expect(
        collapsedNotch.first?.opacity,
        equals: 1.0,
        "collapsed notch scrim stays pure black at the top"
    )
    try expect(
        collapsedNotch.last?.opacity,
        equals: 1.0,
        "collapsed notch scrim stays pure black at the bottom"
    )
}


let tests: [(String, () throws -> Void)] = [
    ("native display uses hardware-notch presentation", testNativeDisplayUsesHardwareNotchPresentation),
    ("native notch restores pre-refactor paddings and transition curve", testNativeNotchRestoresPreRefactorPaddingsAndTransitionCurve),
    ("native notch hides the compact petal mark", testNativeNotchShowsNoCompactMark),
    ("compact control never shows the petal glyph", testCompactControlNeverShowsPetalMark),
    ("collapsed pill derives width from explicit padding", testCollapsedPillDerivesWidthFromExplicitPadding),
    ("external display uses contained pill presentation", testExternalDisplayUsesContainedPillPresentation),
    ("Petalo expanded canvas does not reserve session-list height", testPetaloExpandedCanvasDoesNotReserveSessionListHeight),
    ("screen selection returns every display in all-displays mode", testScreenSelectionReturnsEveryDisplayInAllDisplaysMode),
    ("focused-window mode falls back without window geometry", testFocusedWindowModeFallsBackWithoutWindowGeometry),
    ("screen selection uses greatest intersection and stable tie break", testScreenSelectionUsesGreatestWindowIntersectionAndStableTieBreak),
    ("pointer movement gate requires intent after panel move", testPointerMovementGateRequiresIntentAfterPanelMove),
    ("pointer samples publish only containment changes", testPointerSamplesPublishOnlyContainmentChanges),
    ("hover interaction uses full canvas only when expanded", testHoverInteractionUsesFullCanvasOnlyWhenExpanded),
    ("hanging notch interaction passes transparent corners through", testHangingNotchInteractionPassesTransparentCornersThrough),
    ("panel synchronization owns only required resources", testPanelSynchronizationOwnsOnlyRequiredResources),
    ("single instance lock excludes another instance", testSingleInstanceLockExcludesAnotherInstance),
    ("assistant workflow captures context before prompt and clears after delivery", testAssistantWorkflowCapturesContextBeforeOpeningPromptAndClearsAfterDelivery),
    ("assistant workflow clears sensitive context on cancellation and failure", testAssistantWorkflowClearsSensitiveContextOnCancellationAndFailure),
    ("assistant workflow captures region before prompt and types its image payload", testAssistantWorkflowCapturesRegionBeforePromptAndTypesItsImagePayload),
    ("region selection normalizes and clamps to its invocation display", testRegionSelectionNormalizesAndClampsToItsInvocationDisplay),
    ("normalized region sanitization cannot escape its display", testNormalizedRegionSanitizationCannotEscapeItsDisplay),
    ("shortcut configuration rejects duplicates and restores defaults", testShortcutConfigurationRejectsDuplicatesAndRestoresDefaults),
    ("shortcut configuration rejects direct-prompt duplicate", testShortcutConfigurationRejectsDirectPromptDuplicate),
    ("ChatGPT delivery policy auto-pastes installed app", testChatGPTDeliveryPolicyAutoPastesInstalledApp),
    ("ChatGPT handoff activation schedule grows geometrically and caps", testChatGPTHandoffTimingActivationScheduleGrowsGeometricallyAndCaps),
    ("ChatGPT handoff timing returns nil after max attempts", testChatGPTHandoffTimingReturnsNilAfterMaxAttempts),
    ("ChatGPT handoff recovery schedule is short and caps lower", testChatGPTHandoffTimingRecoveryScheduleIsShortAndCapsLower),
    ("ChatGPT handoff custom schedule honours parameters", testChatGPTHandoffTimingCustomScheduleHonoursParameters),
    ("ChatGPT handoff plan writes clipboard immediately before each paste", testHandoffPlanWritesClipboardImmediatelyBeforeEachPaste),
    ("ChatGPT handoff plan image-only omits text paste when instruction empty", testHandoffPlanImageOnlyOmitsTextPasteWhenInstructionIsEmpty),
    ("ChatGPT handoff plan waits for new conversation to settle", testHandoffPlanWaitsForNewConversationToSettle),
    ("manual completion uses separate prompt and image clipboard steps", testManualCompletionUsesSeparatePromptAndImageClipboardSteps),
    ("assistant workflow rejects empty instruction as terminal failure", testAssistantWorkflowRejectsEmptyInstructionAsTerminalFailure),
    ("assistant workflow allows empty instruction for captured image", testAssistantWorkflowAllowsEmptyInstructionForCapturedImage),
    ("assistant workflow beginDelivery is a no-op outside prompting state", testAssistantWorkflowBeginDeliveryIsNoOpOutsidePromptingState),
    ("assistant workflow rejects new capture while delivering", testAssistantWorkflowRejectsNewCaptureWhileDelivering),
    ("assistant workflow abandonDelivery frees state for new capture", testAssistantWorkflowAbandonDeliveryFreesStateForNewCapture),
    ("assistant workflow abandonDelivery is no-op outside delivering", testAssistantWorkflowAbandonDeliveryIsNoOpOutsideDelivering),
    ("assistant workflow clears payload on completed and failed delivery", testAssistantWorkflowClearsPayloadOnCompletedAndFailedDelivery),
    ("assistant workflow rejects empty selection and empty image bytes", testAssistantWorkflowRejectsEmptySelectionAndEmptyImageBytes),
    ("assistant workflow dismisses failure and only exposes context in owning states", testAssistantWorkflowDismissesFailureAndOnlyExposesContextInOwningStates),
    ("assistant workflow manual completion without in-flight payload fails safely", testAssistantWorkflowManualCompletionWithoutInFlightPayloadFailsSafely),
    ("shortcut configuration rejects missing modifier and accepts disabled shortcuts", testShortcutConfigurationRejectsMissingModifierAndAcceptsDisabledShortcuts),
    ("region selection rejects degenerate drags and reports area", testRegionSelectionRejectsDegenerateDragsAndReportsArea),
    ("normalized region sanitization clamps non-finite input to zero", testNormalizedRegionSanitizationClampsNonFiniteInputToZero),
    ("rounded selection rect clamps radius and rejects degenerate drags", testRoundedSelectionRectClampsRadiusAndRejectsDegenerateDrags),
    ("refraction scales proportionally to selection size", testRefractionScalesProportionallyToSelectionSize),
    ("manual completion combines instruction and selected text into one prompt step", testManualCompletionCombinesInstructionAndSelectedTextIntoOnePromptStep),
    ("combined prompt text merges instruction and selection", testCombinedPromptTextMergesInstructionAndSelection),
    ("combined prompt text for image is instruction only", testCombinedPromptTextForImageIsInstructionOnly),
    ("prompt surface attaches to top on notch display", testPromptSurfaceAttachesToTopOnNotchDisplay),
    ("prompt surface clamps content width to panel", testPromptSurfaceClampsContentWidthToPanel),
    ("prompt surface floats as bubble on external display", testPromptSurfaceFloatsAsBubbleOnExternalDisplay),
    ("prompt surface notch uses larger bubble radius when expanded", testPromptSurfaceNotchUsesLargerBubbleRadiusWhenExpanded),
    ("prompt surface pill keeps bubble radius in both states", testPromptSurfacePillKeepsBubbleRadiusInBothStates),
    ("prompt surface notch uses larger top shoulder radius when expanded", testPromptSurfaceNotchUsesLargerTopShoulderRadiusWhenExpanded),
    ("prompt surface pill top shoulder radius is zero", testPromptSurfacePillTopShoulderRadiusIsZero),
    ("prompt surface image content is taller than text", testPromptSurfaceImageContentIsTallerThanText),
    ("prompt surface selected-text content is taller than text and shorter than image", testPromptSurfaceSelectedTextContentIsTallerThanTextAndShorterThanImage),
    ("prompt surface base panel height matches panel height", testPromptSurfaceBasePanelHeightMatchesPanelHeight),
    ("prompt surface grows with text editor height", testPromptSurfaceGrowsWithTextEditorHeight),
    ("prompt surface stays at base when editor does not exceed base", testPromptSurfaceStaysAtBaseWhenEditorDoesNotExceedBase),
    ("prompt surface shrinks back from grown height", testPromptSurfaceShrinksBackFromGrownHeight),
    ("prompt surface caps editor height at maximum", testPromptSurfaceCapsEditorHeightAtMaximum),
    ("direct prompt from idle delivers none context and clears after delivery", testDirectPromptFromIdleDeliversNoneContextAndClearsAfterDelivery),
    ("direct prompt rejects empty instruction", testDirectPromptRejectsEmptyInstruction),
    ("direct delivery is invalid outside idle", testDirectDeliveryIsInvalidOutsideIdle),
    ("combined prompt text for none context is instruction only", testCombinedPromptTextForNoneContextIsInstructionOnly),
    ("selected text preview snippet collapses whitespace into single spaces", testSelectedTextPreviewSnippetCollapsesWhitespaceIntoSingleSpaces),
    ("prompt key policy makes panel key only while expanded", testPromptKeyPolicyMakesPanelKeyOnlyWhileExpanded),
    ("wobble rests on rigid silhouette at endpoints", testWobbleRestsOnRigidSilhouetteAtEndpoints),
    ("wobble recoils bottom edge upward at crest", testWobbleRecoilsBottomEdgeUpwardAtCrest),
    ("wobble does not affect hit testing", testWobbleDoesNotAffectHitTesting),
    ("drag spring jelly converges and overshoots", testDragSpringJellyConvergesAndOvershoots),
    ("drag spring jelly lags a moving target", testDragSpringJellyLagsMovingTarget),
    ("drag spring rigid is a no-op", testDragSpringRigidIsNoOp),
    ("jelly squash envelope rests on identity at endpoints", testJellySquashEnvelopeRestsOnIdentityAtEndpoints),
    ("jelly squash envelope stretches at first crest", testJellySquashEnvelopeStretchesAtFirstCrest),
    ("release ripple dim fade holds then clears to zero", testReleaseRippleDimFadeHoldsThenClearsToZero),
    ("release ripple hairline flash peaks early and returns to zero", testReleaseRippleHairlineFlashPeaksEarlyAndReturnsToZero),
    ("scaled selection rect keeps center and clamps radius", testScaledSelectionRectKeepsCenterAndClampsRadius),
    ("vertical flip moves release point into top-left space and back", testVerticalFlipMovesReleasePointIntoTopLeftSpaceAndBack),
    ("release ripple shader is spent before the overlay is torn down", testReleaseRippleShaderIsSpentBeforeTheOverlayIsTornDown),
    ("release ripple is one expansion and fades from the cursor outward", testReleaseRippleIsOneExpansionAndFadesFromTheCursorOutward),
    ("release ripple never drags a sample through the impact point", testReleaseRippleNeverDragsASampleThroughTheImpactPoint),
    ("release ripple wavefront crosses a typical selection", testReleaseRippleWavefrontCrossesATypicalSelection),
    ("release ripple speed scales with selection diagonal", testReleaseRippleSpeedScalesWithSelectionDiagonal),
    ("release ripple amplitude scales with the selection size", testReleaseRippleAmplitudeScalesWithTheSelectionSize),
    ("ripple outline rests on the rounded rect at both endpoints", testRippleOutlineRestsOnTheRoundedRectAtBothEndpoints),
    ("ripple outline deforms near the release before the far edge", testRippleOutlineDeformsNearTheReleaseBeforeTheFarEdge),
    ("ripple outline is visible and stays within the hosting margin", testRippleOutlineIsVisibleAndStaysWithinTheHostingMargin),
    ("ripple outline is closed and dense enough to read as a curve", testRippleOutlineIsClosedAndDenseEnoughToReadAsACurve),
    ("notch vertical spring does not overshoot", testNotchVerticalSpringDoesNotOvershoot),
    ("notch horizontal spring may overshoot", testNotchHorizontalSpringMayOvershoot),
    ("notch reduce-motion spring minimizes overshoot", testNotchReduceMotionSpringMinimizesOvershoot),
    ("prompt button zoom exit is inverse of entry", testPromptButtonZoomExitIsInverseOfEntry),
    ("pill collapsed scrim is smoked tint not flat black", testPillCollapsedScrimIsSmokedTintNotFlatBlack),
]

do {
    for (name, test) in tests {
        try test()
        print("PASS: \(name)")
    }
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
