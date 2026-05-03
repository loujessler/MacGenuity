//
//  DiagnosticsWindow.swift
//  MacGenuity
//
//  Tools for contributing new device profiles:
//    • Lists every HyperX-shaped HID interface with full fingerprint
//    • Live tail of structured logs (filterable by channel/level)
//    • Raw packet sender for probing undocumented commands
//

import SwiftUI
import AppKit

struct DiagnosticsWindow: View {
    @ObservedObject var viewModel: DeviceViewModel
    @ObservedObject var logger = FileLogger.shared

    @State private var rawHex: String = "50 00 00 00"
    @State private var sendKind: ProfilePacket.SendKind = .output
    @State private var receiveKind: ProfilePacket.ReceiveKind = .input
    @State private var lastResponse: Data?
    @State private var lastResponseError: String?
    @State private var levelFilter: LogLevel = .debug
    @State private var channelFilter: LogChannel? = nil

    /// Cached candidate list. Discovery touches IOKit and logs each
    /// candidate, so we MUST NOT call it from the view body — every log
    /// line republishes `FileLogger.tail`, which would trigger another
    /// rebuild and another discovery, forever.
    @State private var candidates: [DiagnosticsCandidate] = []

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                candidatesSection
                Divider()
                rawSenderSection
            }
            .padding(12)
            .frame(minHeight: 280)

            logsSection
                .frame(minHeight: 200)
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { refreshCandidates() }
    }

    private func refreshCandidates() {
        candidates = viewModel.deviceService.diagnosticsCandidates()
    }

    // MARK: - Candidates

    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Detected HID interfaces").font(.headline)
                Spacer()
                if let active = viewModel.activeProfile {
                    Label(active.identifier, systemImage: "checkmark.seal")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                Button {
                    refreshCandidates()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-enumerate HID devices")
            }
            if candidates.isEmpty {
                Text("No HyperX-shaped HID interfaces detected.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: DiagnosticsCandidate) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(candidate.fingerprint.product.isEmpty ? "(unnamed)" : candidate.fingerprint.product)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if let resolved = candidate.resolvedProfile {
                    Text(resolved)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                } else {
                    Text("no profile")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(candidate.summary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Raw sender

    private var rawSenderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Raw packet sender").font(.headline)
                Spacer()
                Text("First byte = command for response matching")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Picker("Send", selection: $sendKind) {
                    Text("Output").tag(ProfilePacket.SendKind.output)
                    Text("Feature").tag(ProfilePacket.SendKind.feature)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Picker("Receive", selection: $receiveKind) {
                    Text("Input").tag(ProfilePacket.ReceiveKind.input)
                    Text("Feature").tag(ProfilePacket.ReceiveKind.feature)
                    Text("None").tag(ProfilePacket.ReceiveKind.none)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
            }

            HStack(spacing: 6) {
                TextField("hex bytes (e.g. 50 00 00 00 or D2 20 12 08 ...)", text: $rawHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                Button("Send") { Task { await sendRaw() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(rawHex.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let err = lastResponseError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            if let response = lastResponse {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Response (\(response.count) bytes)")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button("Copy hex") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(response.hexString, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text(response.hexString)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func sendRaw() async {
        guard var bytes = Data.parseHex(rawHex) else {
            lastResponseError = "Could not parse hex. Use space- or comma-separated hex bytes."
            lastResponse = nil
            return
        }
        // Pad / truncate to 64 bytes — the HID transport rejects other sizes.
        if bytes.count < HIDTransport.packetSize {
            bytes.append(Data(count: HIDTransport.packetSize - bytes.count))
        } else if bytes.count > HIDTransport.packetSize {
            bytes = bytes.prefix(HIDTransport.packetSize)
        }

        do {
            lastResponseError = nil
            let response = try await viewModel.deviceService.sendRawPacket(
                bytes, sendKind: sendKind, receiveKind: receiveKind
            )
            lastResponse = response ?? Data()
        } catch {
            lastResponseError = error.localizedDescription
            lastResponse = nil
        }
    }

    // MARK: - Logs

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live log tail").font(.headline)

                Picker("Level", selection: $levelFilter) {
                    Text("Debug").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Warn").tag(LogLevel.warning)
                    Text("Error").tag(LogLevel.error)
                }
                .frame(width: 120)

                Picker("Channel", selection: $channelFilter) {
                    Text("All").tag(LogChannel?.none)
                    Text("HID").tag(LogChannel?.some(.hid))
                    Text("Audio").tag(LogChannel?.some(.audio))
                    Text("Battery").tag(LogChannel?.some(.battery))
                    Text("Lighting").tag(LogChannel?.some(.lighting))
                    Text("App").tag(LogChannel?.some(.app))
                }
                .frame(width: 140)

                Spacer()

                Button("Copy") {
                    let text = filteredEntries.map { format($0) }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.bordered)

                Button("Open log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([logger.fileURL])
                }
                .buttonStyle(.bordered)

                Button("Clear") { logger.clearTail() }
                    .buttonStyle(.bordered)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            Text(format(entry))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                                .id(entry.id)
                                .textSelection(.enabled)
                        }
                    }
                }
                .onChange(of: filteredEntries.last?.id) { newID in
                    if let newID { withAnimation { proxy.scrollTo(newID, anchor: .bottom) } }
                }
            }
            .background(Color.gray.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
    }

    private var filteredEntries: [LogEntry] {
        logger.tail.filter { entry in
            entry.level >= levelFilter && (channelFilter == nil || channelFilter == entry.channel)
        }
    }

    private func format(_ entry: LogEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return "\(formatter.string(from: entry.date)) [\(entry.level.label)] [\(entry.channel.rawValue)] \(entry.message)"
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug:   return .secondary
        case .info:    return .primary
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
