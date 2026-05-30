import SwiftUI
import AppKit

@MainActor
public final class ScreenRecordHUDController: @unchecked Sendable {
    public static let shared = ScreenRecordHUDController()
    
    public static var statusItemFrameProvider: (@MainActor () -> NSRect?)?
    
    private var window: NSPanel?
    
    private init() {}
    
    public func show(device: AndroidDevice, model: DroidScoutModel) {
        if window != nil {
            dismiss()
        }
        
        let hudView = ScreenRecordHUDView(device: device, model: model) { [weak self] in
            self?.dismiss()
            model.stopScreenRecording(device: device)
        } onDiscard: { [weak self] in
            self?.dismiss()
            model.discardScreenRecording(device: device)
        }
        
        let hostingView = NSHostingView(rootView: hudView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 190)
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 190),
            styleMask: [.utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        
        if let statusFrame = Self.statusItemFrameProvider?() {
            let panelWidth: CGFloat = 340
            let panelHeight: CGFloat = 190
            var x = statusFrame.midX - (panelWidth / 2)
            let y = statusFrame.minY - panelHeight - 8
            
            if let screen = NSScreen.screens.first {
                let maxBound = screen.visibleFrame.maxX - panelWidth - 12
                let minBound = screen.visibleFrame.minX + 12
                x = max(minBound, min(x, maxBound))
            }
            
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        } else {
            panel.center()
        }
        
        panel.orderFrontRegardless()
        panel.makeKey()
        
        self.window = panel
    }
    
    public func dismiss() {
        window?.close()
        window = nil
    }
}

struct ScreenRecordHUDView: View {
    let device: AndroidDevice
    let model: DroidScoutModel
    let onStop: () -> Void
    let onDiscard: () -> Void
    
    @State private var timeElapsed: Int = 0
    @State private var isPulsing = false
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Droid Scout")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(isPulsing ? 1.3 : 1.0)
                        .opacity(isPulsing ? 0.4 : 1.0)
                        .onAppear {
                            withAnimation(Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                isPulsing = true
                            }
                        }
                    Text("RECORDING")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                }
            }
            .padding(.top, 14)
            
            Divider()
                .opacity(0.3)
                .padding(.bottom, 4)
            
            Text(timeString(timeElapsed))
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .onReceive(timer) { _ in
                    timeElapsed += 1
                }
            
            Text(device.friendlyName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            
            Spacer()
            
            HStack(spacing: 12) {
                Button(action: onDiscard) {
                    Text("Discard")
                        .foregroundColor(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
                
                Button(action: {}) {
                    Text("Pause")
                        .foregroundColor(.gray)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .disabled(true)
                .help("Pause is not supported by ADB screenrecord")
                
                Button(action: onStop) {
                    Text("Stop & Save")
                        .foregroundColor(.white)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue)
                )
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 18)
        .frame(width: 340, height: 190)
    }
    
    private func timeString(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
