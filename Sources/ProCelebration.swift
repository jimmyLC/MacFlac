import SwiftUI
import AppKit

// Adapted for native macOS from first-payment-fireworks (MIT), by JimmyLC.
@MainActor enum ProCelebrationWindow {
    private static var panel: NSPanel?
    private static var activationObserver: NSObjectProtocol?
    static func show(onClose: @escaping () -> Void) {
        guard panel == nil, activationObserver == nil else { return }
        // Payment happens in the browser. Wait until the customer returns so the
        // animation does not finish while this app is in the background.
        if !NSApp.isActive {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    if let observer = activationObserver { NotificationCenter.default.removeObserver(observer) }
                    activationObserver = nil
                    show(onClose: onClose)
                }
            }
            return
        }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 330),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L("恭喜升級 Pro")
        window.isFloatingPanel = true
        window.level = .floating
        window.contentView = NSHostingView(rootView: ProCelebrationView {
            panel?.close(); panel = nil; onClose()
        })
        window.center()
        panel = window
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ProCelebrationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false
    let close: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                Image(systemName: "heart.fill").font(.system(size: 40)).foregroundStyle(.blue)
                Text(L("恭喜升級 Pro")).font(.title2.bold())
                Text(L("謝謝你的支持！Pro 功能已啟用。"))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L("太棒了"), action: close).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }.padding(32)
            if !reduceMotion && !finished {
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(start)
                    Canvas { context, size in
                        let colors: [Color] = [.red, .yellow, .mint, .blue, .purple, .pink, .white]
                        for shell in 0..<8 {
                            let t = elapsed - Double(shell) * 0.21
                            let x = size.width * (0.14 + Double((shell * 37) % 72) / 100)
                            let target = size.height * (0.14 + Double((shell * 19) % 30) / 100)
                            if t >= 0 && t < 0.36 {
                                let y = size.height - (size.height - target) * (t / 0.36)
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 4, height: 4)), with: .color(.yellow))
                            } else if t >= 0.36 && t < 1.4 {
                                let age = t - 0.36
                                for spark in 0..<36 {
                                    let angle = Double(spark) * .pi * 2 / 36
                                    let distance = (1 - exp(-age * 2.4)) * (45 + Double(spark % 5) * 5)
                                    let point = CGPoint(x: x + cos(angle) * distance, y: target + sin(angle) * distance + age * age * 18)
                                    let rect = CGRect(x: point.x, y: point.y, width: 3.5, height: 3.5)
                                    context.fill(Path(ellipseIn: rect), with: .color(colors[(shell + spark / 12) % colors.count].opacity(max(0, 1 - age))))
                                }
                            }
                        }
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { try? await Task.sleep(nanoseconds: 3_300_000_000); finished = true }
    }
}

