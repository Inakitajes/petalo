import AppKit
import SwiftUI

import PetaloCore

/// The explicit fallback for providers without a supported multipart compose
/// API. It keeps text and image pasteboard writes separate, with instructions
/// to paste each item before copying the next one.
@MainActor
final class ManualCompletionPanelController {
    private let panel: KeyCapablePanel

    init() {
        panel = KeyCapablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
    }

    func show(
        payload: AssistantPayload,
        on screen: NSScreen,
        presentation: NotchLayout.Presentation,
        onCopy: @escaping (ManualCompletionStep) -> Void,
        onOpenChatGPT: @escaping () -> Void,
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let height: CGFloat = {
            if case .capturedImage = payload.context { return 382 }
            return 300
        }()
        let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let attachmentDepth = max(screen.safeAreaInsets.top, menuBarHeight) + 190
        let attachedTop = screen.frame.maxY - attachmentDepth
        let frame = NSRect(
            x: screen.frame.midX - 280,
            y: max(screen.visibleFrame.minY, attachedTop - height),
            width: 560,
            height: height
        )
        panel.onCancel = onCancel
        panel.contentView = NSHostingView(
            rootView: ManualCompletionView(
                payload: payload,
                presentation: presentation,
                onCopy: onCopy,
                onOpenChatGPT: onOpenChatGPT,
                onDone: onDone,
                onCancel: onCancel
            )
        )
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
        panel.onCancel = nil
        panel.contentView = nil
    }
}

private struct ManualCompletionView: View {
    @AppStorage("glassFrostRadiusNotch") private var notchFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityNotch") private var notchTintOpacity = NotchGlassStyle.defaultTintOpacity
    @AppStorage("glassFrostRadiusPill") private var pillFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityPill") private var pillTintOpacity = NotchGlassStyle.defaultTintOpacity

    let payload: AssistantPayload
    let presentation: NotchLayout.Presentation
    let onCopy: (ManualCompletionStep) -> Void
    let onOpenChatGPT: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void
    @State private var copiedSteps: Set<Int> = []

    var body: some View {
        let shape = HangingNotchShape(
            style: .bubble,
            topShoulderRadius: HangingNotchMetrics.topShoulderRadius,
            bottomCornerRadius: HangingNotchMetrics.bottomCornerRadius
        )
        ZStack {
            NotchGlassBackdrop(presentation: .pill, frostRadius: frostRadius)
            NotchGlassScrim(
                silhouette: shape,
                barBandHeight: 0,
                presentation: .pill,
                tintOpacity: tintOpacity
            )
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("Finish in ChatGPT", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.58))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel manual completion")
                }
                .foregroundStyle(.white.opacity(0.9))

                Text(instructions)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))

                if case let .capturedImage(image) = payload.context,
                   let preview = NSImage(data: image.data) {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .modifier(LiquidGlassPreviewOverlay(cornerRadius: 20))
                        .frame(maxWidth: .infinity)
                }

                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack {
                        Image(systemName: copiedSteps.contains(index) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(copiedSteps.contains(index) ? .green : .white.opacity(0.58))
                        Text(stepTitle(step, index: index))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button(copyButtonTitle(step)) {
                            copiedSteps.insert(index)
                            onCopy(step)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .foregroundStyle(.white.opacity(0.84))
                }

                HStack {
                    Button("Open ChatGPT", action: onOpenChatGPT)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                }
                Text("Petalo cannot create or send a ChatGPT message. Paste each copied item yourself, then choose Done to clear it.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.58))
            }
            .padding(18)
        }
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(0.15), lineWidth: 1))
    }

    private var steps: [ManualCompletionStep] {
        ManualCompletionPlan.steps(for: payload)
    }

    private var instructions: String {
        steps.count == 1
            ? "Copy the prepared prompt, paste it into ChatGPT, then choose Done."
            : "Copy the prompt and paste it into ChatGPT before copying and pasting the image."
    }

    private var frostRadius: Double {
        presentation == .notch ? notchFrostRadius : pillFrostRadius
    }

    private var tintOpacity: Double {
        presentation == .notch ? notchTintOpacity : pillTintOpacity
    }

    private func stepTitle(_ step: ManualCompletionStep, index: Int) -> String {
        switch step {
        case .copyPrompt:
            steps.count == 1 ? "Prepared prompt" : "Step \(index + 1): prompt"
        case .copyImage:
            "Step \(index + 1): image"
        }
    }

    private func copyButtonTitle(_ step: ManualCompletionStep) -> String {
        switch step {
        case .copyPrompt: "Copy prompt"
        case .copyImage: "Copy image"
        }
    }
}
