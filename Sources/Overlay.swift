import AppKit
import SwiftUI

final class RecorderState: ObservableObject {
    @Published var level: CGFloat = 0          // 0...1, fast attack / slow release
    @Published var transcribing = false
    @Published var startedAt = Date()
    @Published var partial = ""                 // live Apple transcript
    @Published var status = ""                  // e.g. "Cleaning up…"
}

// MARK: - Overlay UI

struct OverlayView: View {
    @ObservedObject var state: RecorderState
    @State private var breathe = false
    private let barCount = 30

    var body: some View {
        VStack(spacing: -14) {   // pill carries 24pt shadow padding
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(state.status.isEmpty ? 0.9 : 0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .frame(maxWidth: 520)
                    .transition(.opacity)
            }
            pill
        }
        .animation(.easeOut(duration: 0.15), value: caption.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var caption: String { state.status.isEmpty ? state.partial : state.status }

    private var pill: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(red: 1, green: 0.23, blue: 0.27))
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(breathe ? 0.9 : 0.3), radius: breathe ? 6 : 2)
                .opacity(breathe ? 1 : 0.65)

            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<barCount, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(state.transcribing ? 0.35 : 0.92))
                            .frame(width: 2.5, height: barHeight(i, t))
                    }
                }
                .frame(height: 26)
            }

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(ctx.date))
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(Capsule().fill(Color.black.opacity(0.35)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
        .padding(24)   // room for the shadow
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    /// Symmetric bell-shaped envelope, rippled by a few slow sines and scaled by the mic level.
    private func barHeight(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let x = Double(i) / Double(barCount - 1) * 2 - 1          // -1...1
        let envelope = exp(-x * x * 2.2)
        let wave = 0.55 + 0.25 * sin(t * 7.0 + Double(i) * 0.55) + 0.2 * sin(t * 4.3 - Double(i) * 0.9)
        let lvl = state.transcribing ? 0.0 : Double(state.level)
        let idle = 0.08 + 0.04 * sin(t * 2.5 + Double(i) * 0.4)
        return CGFloat(3 + 23 * max(idle, lvl * envelope * wave))
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(state.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class OverlayPanel: NSPanel {
    // Fixed transparent canvas; the pill sits at its bottom center and the live caption grows above it.
    private static let size = NSSize(width: 600, height: 150)

    init(state: RecorderState) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: OverlayView(state: state))
        host.frame = contentRect(forFrameRect: frame)
        contentView = host
    }

    func showBottomCenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = Self.size
        let target = NSRect(x: vf.midX - size.width / 2, y: vf.minY + 16, width: size.width, height: size.height)
        setFrame(target.offsetBy(dx: 0, dy: -10), display: true)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.18
            $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({
            $0.duration = 0.18
            animator().alphaValue = 0
            animator().setFrame(frame.offsetBy(dx: 0, dy: -8), display: true)
        },
                                             completionHandler: { self.orderOut(nil) })
    }
}
