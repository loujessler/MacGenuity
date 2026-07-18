// Hardware-free regression coverage for the QuadCast 2 S LampArray feature.
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private enum QuadCast2STests {
    @MainActor
    static func main() throws {
        try testLiveArrayAttributes()
        try testLampAttributes()
        try testStaticReports()
        try testAtomicMultiUpdateBatches()
        try testInvalidFrames()
        try testKnownGeometry()
        try testEffectRenderer()
        try testLegacyPreferenceMigration()
        try testStatePersistence()
        print("QuadCast 2 S tests passed")
    }

    private static func testLiveArrayAttributes() throws {
        let liveReport = Data([
            0x01, 0x6C, 0x00, 0xE0, 0x8C, 0x01, 0x00, 0x38,
            0x0C, 0x02, 0x00, 0x64, 0xE8, 0x03, 0x00, 0x04,
            0x00, 0x00, 0x00, 0xE8, 0x80, 0x00, 0x00
        ])
        let attributes = try QuadCast2SProtocol.parseLampArrayAttributes(liveReport)
        try expect(attributes.lampCount == 108, "live report should expose 108 lamps")
        try expect(attributes.boundingBoxWidth == 101_600, "unexpected array width")
        try expect(attributes.boundingBoxHeight == 134_200, "unexpected array height")
        try expect(attributes.boundingBoxDepth == 256_100, "unexpected array depth")
        try expect(attributes.kind == 4, "unexpected LampArray kind")
        try expect(
            attributes.minimumUpdateIntervalMicroseconds == 33_000,
            "live minimum update interval should be 33 ms"
        )
        try expect(
            abs(attributes.maximumFramesPerSecond - 30.303) < 0.001,
            "maximum frame rate should be derived from the device"
        )
    }

    private static func testLampAttributes() throws {
        var report = Data([0x03])
        append(UInt16(17), to: &report)
        append(UInt32(34_500), to: &report)
        append(UInt32(73_500), to: &report)
        append(UInt32(100_700), to: &report)
        append(UInt32(5_000), to: &report)
        append(UInt32(1), to: &report)
        report.append(contentsOf: [255, 255, 255, 255, 1, 0])

        let lamp = try QuadCast2SProtocol.parseLampAttributes(report)
        try expect(lamp.id == 17, "lamp ID did not round-trip")
        try expect(lamp.x == 34_500 && lamp.y == 73_500, "lamp XY geometry is wrong")
        try expect(lamp.z == 100_700, "lamp Z geometry is wrong")
        try expect(lamp.updateLatencyMicroseconds == 5_000, "lamp latency is wrong")
        try expect(lamp.isProgrammable, "live lamp should be programmable")
        try expect(
            lamp.redLevelCount == 255
                && lamp.greenLevelCount == 255
                && lamp.blueLevelCount == 255
                && lamp.intensityLevelCount == 255,
            "lamp should expose full RGBI resolution"
        )
    }

    private static func testStaticReports() throws {
        let reports = QuadCast2SProtocol.staticLightingReports(
            color: RGBColor(red: 300, green: -4, blue: 127),
            brightness: 40
        )
        try expect(reports == [
            Data([0x06, 0x00]),
            Data([0x05, 0x01, 0x00, 0x00, 0x6B, 0x00, 0xFF, 0x00, 0x7F, 0x66])
        ], "static lighting reports changed")
        try expect(
            QuadCast2SProtocol.restoreAutonomousLightingReport == Data([0x06, 0x01]),
            "autonomous-mode report changed"
        )
    }

    private static func testAtomicMultiUpdateBatches() throws {
        let values = (0..<108).map { lampID in
            QuadCast2SLampValue(
                lampID: UInt16(lampID),
                color: RGBColor(
                    red: lampID,
                    green: 255 - lampID,
                    blue: lampID * 3
                ),
                intensity: lampID * 4
            )
        }
        let reports = try QuadCast2SProtocol.multiUpdateReports(values: values)

        try expect(reports.count == 14, "108 lamps should require fourteen batches")
        try expect(reports.allSatisfy { $0.count == 51 }, "every batch must be 51 bytes")
        try expect(
            reports.dropLast().allSatisfy { $0[2] == 0 },
            "only the final batch may carry LampUpdateComplete"
        )
        try expect(reports[0][0] == 0x04 && reports[0][1] == 8, "first batch header is wrong")
        try expect(reports[0][3] == 0 && reports[0][17] == 7, "first eight IDs are wrong")
        try expect(
            Array(reports[0][19...22]) == [0, 255, 0, 0],
            "first RGBI slot is wrong"
        )

        let final = reports[13]
        try expect(final[1] == 4 && final[2] == 1, "final batch header is wrong")
        try expect(final[3] == 104 && final[9] == 107, "final four IDs are wrong")
        try expect(
            Array(final[31...34]) == [107, 148, 255, 255],
            "last RGBI slot should be clamped and correctly positioned"
        )
    }

    private static func testInvalidFrames() throws {
        try expectInvalidFrame("no lamp values") {
            _ = try QuadCast2SProtocol.multiUpdateReports(values: [])
        }
        let duplicate = QuadCast2SLampValue(
            lampID: 4,
            color: PresetColor.cyan.rgb,
            intensity: 255
        )
        try expectInvalidFrame("duplicate lamp IDs") {
            _ = try QuadCast2SProtocol.multiUpdateReports(values: [duplicate, duplicate])
        }
        try expectInvalidFrame("outside the array") {
            _ = try QuadCast2SProtocol.multiUpdateReports(values: [
                QuadCast2SLampValue(
                    lampID: 108,
                    color: PresetColor.red.rgb,
                    intensity: 255
                )
            ])
        }
    }

    private static func testKnownGeometry() throws {
        let lamps = QuadCast2SLampLayout.knownQuadCast2S
        try expect(lamps.count == 108, "fallback geometry should contain 108 lamps")
        try expect(Set(lamps.map(\.id)).count == 108, "fallback lamp IDs must be unique")
        try expect(
            QuadCast2SLampLayout.lampID(column: 0, row: 0) == 8
                && QuadCast2SLampLayout.lampID(column: 0, row: 8) == 0
                && QuadCast2SLampLayout.lampID(column: 1, row: 0) == 9
                && QuadCast2SLampLayout.lampID(column: 1, row: 8) == 17,
            "custom canvas must follow the physical serpentine wiring"
        )
        try expect(Set(lamps.map(\.z)).count == 9, "fallback geometry should have nine rows")
        try expect(
            Set(lamps.map { "\($0.x):\($0.y)" }).count == 12,
            "fallback geometry should have twelve cylindrical columns"
        )
    }

    private static func testEffectRenderer() throws {
        let lamps = QuadCast2SLampLayout.knownQuadCast2S
        for kind in QuadCast2SEffectKind.allCases {
            var configuration = QuadCast2SEffectConfiguration.default
            configuration.kind = kind
            configuration.palette = [PresetColor.red.rgb, PresetColor.cyan.rgb]
            configuration.brightness = 50
            let frame = QuadCast2SEffectRenderer.render(
                configuration: configuration,
                lamps: lamps,
                elapsedTime: 0.375
            )
            try expect(frame.count == 108, "\(kind.rawValue) did not render every lamp")
            try expect(
                frame.allSatisfy { (0...255).contains($0.intensity) },
                "\(kind.rawValue) emitted an invalid intensity"
            )
        }

        var solid = QuadCast2SEffectConfiguration.default
        solid.kind = .solid
        solid.palette = [RGBColor(red: 12, green: 34, blue: 56)]
        solid.brightness = 50
        let solidFrame = QuadCast2SEffectRenderer.render(
            configuration: solid,
            lamps: lamps,
            elapsedTime: 9
        )
        try expect(
            solidFrame.allSatisfy { $0.color == solid.palette[0] && $0.intensity == 128 },
            "solid renderer should produce one stable RGBI value"
        )

        var spectrum = QuadCast2SEffectConfiguration.default
        spectrum.kind = .spectrum
        spectrum.speed = 1
        let spectrumA = QuadCast2SEffectRenderer.render(
            configuration: spectrum,
            lamps: lamps,
            elapsedTime: 0
        )
        let spectrumB = QuadCast2SEffectRenderer.render(
            configuration: spectrum,
            lamps: lamps,
            elapsedTime: 0.2
        )
        try expect(Set(spectrumA.map(\.color)).count > 8, "spectrum should use spatial colour")
        try expect(spectrumA != spectrumB, "animated spectrum should advance with time")

        var sparkle = QuadCast2SEffectConfiguration.default
        sparkle.kind = .sparkle
        let sparkleA = QuadCast2SEffectRenderer.render(
            configuration: sparkle,
            lamps: lamps,
            elapsedTime: 1.25
        )
        let sparkleB = QuadCast2SEffectRenderer.render(
            configuration: sparkle,
            lamps: lamps,
            elapsedTime: 1.25
        )
        try expect(sparkleA == sparkleB, "sparkle must be deterministic for a given frame")

        var custom = QuadCast2SEffectConfiguration.default
        custom.kind = .custom
        custom.customColors = (0..<108).map {
            RGBColor(red: $0, green: 0, blue: 255 - $0)
        }
        let customFrame = QuadCast2SEffectRenderer.render(
            configuration: custom,
            lamps: lamps.reversed(),
            elapsedTime: 0
        )
        try expect(
            customFrame.first?.lampID == 107
                && customFrame.first?.color == custom.customColors[107],
            "custom colours must be addressed by lamp ID, not collection order"
        )

        var animator = QuadCast2SEffectConfiguration.default
        animator.kind = .frameAnimator
        animator.customFrames = [
            Array(repeating: PresetColor.red.rgb, count: 108),
            Array(repeating: PresetColor.blue.rgb, count: 108)
        ]
        animator.frameDuration = 1
        animator.frameTransition = .hold
        animator.framePlayback = .loop
        let firstAuthoredFrame = QuadCast2SEffectRenderer.render(
            configuration: animator,
            lamps: lamps,
            elapsedTime: 0.2
        )
        let secondAuthoredFrame = QuadCast2SEffectRenderer.render(
            configuration: animator,
            lamps: lamps,
            elapsedTime: 1.2
        )
        let loopedAuthoredFrame = QuadCast2SEffectRenderer.render(
            configuration: animator,
            lamps: lamps,
            elapsedTime: 2.2
        )
        try expect(
            firstAuthoredFrame.allSatisfy { $0.color == PresetColor.red.rgb }
                && secondAuthoredFrame.allSatisfy { $0.color == PresetColor.blue.rgb }
                && loopedAuthoredFrame.allSatisfy { $0.color == PresetColor.red.rgb },
            "authored animation frames should advance and loop"
        )

        animator.frameTransition = .crossFade
        let blendedFrame = QuadCast2SEffectRenderer.render(
            configuration: animator,
            lamps: Array(lamps.prefix(1)),
            elapsedTime: 0.5
        )
        try expect(
            blendedFrame.first?.color
                == QuadCast2SEffectRenderer.interpolate(
                    PresetColor.red.rgb,
                    PresetColor.blue.rgb,
                    amount: 0.5
                ),
            "authored animation cross-fade should interpolate frames"
        )

        animator.direction = .reverse
        animator.frameTransition = .hold
        let reverseStart = QuadCast2SEffectRenderer.render(
            configuration: animator,
            lamps: Array(lamps.prefix(1)),
            elapsedTime: 0.5
        )
        try expect(
            reverseStart.first?.color == PresetColor.red.rgb,
            "reverse playback should hold the first frame for a full interval"
        )
    }

    private static func testLegacyPreferenceMigration() throws {
        let legacy = Data(#"{"mode":"staticColor","color":{"red":300,"green":-5,"blue":40},"brightness":42}"#.utf8)
        let preference = try JSONDecoder().decode(
            QuadCast2SLightingPreference.self,
            from: legacy
        )
        try expect(preference.mode == .staticColor, "legacy lighting mode was not retained")
        try expect(
            preference.configuration.kind == .solid
                && preference.color == RGBColor(red: 255, green: 0, blue: 40)
                && preference.brightness == 42,
            "legacy solid-colour preferences were not migrated"
        )
        try expect(
            preference.configuration.customColors.count == 108,
            "migration should seed the custom canvas"
        )
        try expect(
            preference.configuration.customFrames.count == 1
                && preference.configuration.customFrames[0].count == 108,
            "migration should seed one editable animation frame"
        )
        let roundTrip = try JSONDecoder().decode(
            QuadCast2SLightingPreference.self,
            from: JSONEncoder().encode(preference)
        )
        try expect(roundTrip == preference, "migrated preference did not round-trip")
    }

    @MainActor
    private static func testStatePersistence() throws {
        let suite = "io.github.loujessler.macgenuity.tests.quadcast2s"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw TestFailure(description: "could not create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let microphone = MicrophoneInfo(
            id: 1,
            name: "HyperX QuadCast 2 S",
            manufacturer: "HP, Inc",
            uid: "test.quadcast2s",
            sampleRate: 48_000,
            inputStreamCount: 1,
            volumePercent: 68,
            isMuted: false,
            isDefaultInput: true
        )
        var configuration = QuadCast2SEffectConfiguration.default
        configuration.kind = .wave
        configuration.palette = [PresetColor.orange.rgb, PresetColor.cyan.rgb]
        configuration.speed = 1.4
        let expected = QuadCast2SLightingPreference(
            mode: .hostEffect,
            configuration: configuration
        )

        QuadCast2SStateStore(defaults: defaults).record(expected, for: microphone)
        let restored = QuadCast2SStateStore(defaults: defaults).preference(for: microphone)
        try expect(restored == expected, "effect configuration was not persisted per microphone")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw TestFailure(description: message) }
    }

    private static func expectInvalidFrame(
        _ reasonFragment: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw TestFailure(description: "expected an invalid-lighting-frame error")
        } catch let error as QuadCast2SError {
            guard case .invalidLightingFrame(let reason) = error,
                  reason.contains(reasonFragment)
            else {
                throw TestFailure(description: "unexpected frame error: \(error)")
            }
        }
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
