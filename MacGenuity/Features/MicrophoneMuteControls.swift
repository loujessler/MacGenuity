import SwiftUI

struct MicrophoneMuteControls: View {
    let microphone: MicrophoneInfo
    @ObservedObject var viewModel: DeviceViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text(microphone.muteStatus ?? "Mute unavailable")
                .font(.caption).foregroundStyle(DeviceTheme.caption)
            if microphone.needsSystemUnmute && microphone.canSetMute {
                Button("Unmute in macOS") {
                    viewModel.applyMicrophoneMute(.system(false), for: microphone)
                }
                .controlSize(.small)
                .help("Unmute this input for apps that are using it, including active calls.")
            } else if microphone.canToggleMute, let muted = microphone.controlMuteState {
                Toggle("\(microphone.displayName) live input", isOn: Binding(
                    get: { !muted },
                    set: { live in
                        let action: MicrophoneMuteAction = microphone.isSoloCast ? .soloCastHardware(!live) : .system(!live)
                        viewModel.applyMicrophoneMute(action, for: microphone)
                    }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(muted ? "Unmute microphone" : "Mute microphone")
            }
        }
        .task(id: microphone.hardwareMuted == nil ? nil : microphone.uid) {
            await viewModel.observeSoloCastMute(for: microphone)
        }
    }
}
