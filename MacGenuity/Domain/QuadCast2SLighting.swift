//
//  QuadCast2SLighting.swift
//  MacGenuity
//
//  Value types for the QuadCast 2 S's standards-based LampArray. Effects are
//  expressed independently from IOKit so rendering and packet construction
//  remain deterministic and testable without hardware.
//

import Foundation

struct QuadCast2SLampArrayAttributes: Equatable {
    let lampCount: Int
    let boundingBoxWidth: UInt32
    let boundingBoxHeight: UInt32
    let boundingBoxDepth: UInt32
    let kind: UInt32
    let minimumUpdateIntervalMicroseconds: UInt32

    var maximumFramesPerSecond: Double {
        guard minimumUpdateIntervalMicroseconds > 0 else { return 30 }
        return 1_000_000 / Double(minimumUpdateIntervalMicroseconds)
    }
}

struct QuadCast2SLamp: Identifiable, Equatable, Hashable {
    let id: UInt16
    let x: UInt32
    let y: UInt32
    let z: UInt32
    let updateLatencyMicroseconds: UInt32
    let purposes: UInt32
    let redLevelCount: UInt8
    let greenLevelCount: UInt8
    let blueLevelCount: UInt8
    let intensityLevelCount: UInt8
    let isProgrammable: Bool
    let inputBinding: UInt8
}

struct QuadCast2SLampValue: Equatable {
    let lampID: UInt16
    let color: RGBColor
    let intensity: Int

    func normalized() -> QuadCast2SLampValue {
        QuadCast2SLampValue(
            lampID: lampID,
            color: color.clamped(),
            intensity: max(0, min(255, intensity))
        )
    }
}

enum QuadCast2SEffectKind: String, CaseIterable, Identifiable, Codable {
    case solid
    case colorCycle
    case gradient
    case spectrum
    case wave
    case orbit
    case breathing
    case sparkle
    case custom
    case frameAnimator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid:       return "Solid"
        case .colorCycle:  return "Colour cycle"
        case .gradient:    return "Flowing gradient"
        case .spectrum:    return "Spectrum"
        case .wave:        return "Wave"
        case .orbit:       return "Orbit"
        case .breathing:   return "Breathing"
        case .sparkle:     return "Sparkle"
        case .custom:      return "Custom canvas"
        case .frameAnimator: return "Frame animator"
        }
    }

    var detail: String {
        switch self {
        case .solid:       return "One colour across every LED"
        case .colorCycle:  return "The entire microphone moves through your palette"
        case .gradient:    return "A smooth palette mapped across the LED geometry"
        case .spectrum:    return "A full animated hue wheel"
        case .wave:        return "Travelling colour and brightness bands"
        case .orbit:       return "A bright head with a fading spatial trail"
        case .breathing:   return "A gentle whole-device pulse"
        case .sparkle:     return "Independent deterministic twinkles"
        case .custom:      return "Paint all 108 LEDs individually"
        case .frameAnimator: return "Paint and animate a sequence of 108-LED frames"
        }
    }

    var iconName: String {
        switch self {
        case .solid:       return "circle.fill"
        case .colorCycle:  return "paintpalette.fill"
        case .gradient:    return "circle.lefthalf.filled"
        case .spectrum:    return "rainbow"
        case .wave:        return "waveform.path"
        case .orbit:       return "dot.circle.and.hand.point.up.left.fill"
        case .breathing:   return "wind"
        case .sparkle:     return "sparkles"
        case .custom:      return "square.grid.3x3.fill"
        case .frameAnimator: return "rectangle.stack.badge.play.fill"
        }
    }

    var isAnimated: Bool {
        self != .solid && self != .custom
    }

    var usesSpeedControl: Bool {
        isAnimated && self != .frameAnimator
    }

    var usesAxis: Bool {
        switch self {
        case .gradient, .spectrum, .wave, .orbit: return true
        default: return false
        }
    }

    var usesSpread: Bool {
        usesAxis
    }

    var usesSoftness: Bool {
        self == .orbit || self == .sparkle
    }

    var usesDirection: Bool {
        switch self {
        case .gradient, .spectrum, .wave, .orbit, .colorCycle, .frameAnimator:
            return true
        default: return false
        }
    }

    var minimumPaletteCount: Int {
        switch self {
        case .solid, .spectrum, .breathing: return 1
        default: return 2
        }
    }
}

enum QuadCast2SFrameTransition: String, CaseIterable, Identifiable, Codable {
    case hold
    case crossFade

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold:      return "Hold"
        case .crossFade: return "Cross-fade"
        }
    }
}

enum QuadCast2SFramePlayback: String, CaseIterable, Identifiable, Codable {
    case loop
    case pingPong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop:     return "Loop"
        case .pingPong: return "Ping-pong"
        }
    }
}

enum QuadCast2SEffectAxis: String, CaseIterable, Identifiable, Codable {
    case around
    case vertical
    case diagonal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .around:   return "Around"
        case .vertical: return "Vertical"
        case .diagonal: return "Diagonal"
        }
    }

    var iconName: String {
        switch self {
        case .around:   return "arrow.clockwise"
        case .vertical: return "arrow.up.and.down"
        case .diagonal: return "arrow.up.right"
        }
    }
}

enum QuadCast2SEffectDirection: String, CaseIterable, Identifiable, Codable {
    case forward
    case reverse

    var id: String { rawValue }
    var multiplier: Double { self == .forward ? 1 : -1 }
}

struct QuadCast2SEffectConfiguration: Codable, Equatable {
    var kind: QuadCast2SEffectKind
    var palette: [RGBColor]
    var brightness: Int
    /// Animation cycles per second.
    var speed: Double
    var axis: QuadCast2SEffectAxis
    var direction: QuadCast2SEffectDirection
    /// Number of spatial repetitions across the selected axis.
    var spread: Double
    /// Trail width / twinkle smoothness, depending on the effect.
    var softness: Double
    /// Lamp-ID ordered colours for the 12 × 9 custom canvas.
    var customColors: [RGBColor]
    /// Each frame is Lamp-ID ordered and independently editable.
    var customFrames: [[RGBColor]]
    /// Seconds spent on each custom animation frame at 1× playback.
    var frameDuration: Double
    var frameTransition: QuadCast2SFrameTransition
    var framePlayback: QuadCast2SFramePlayback

    static let maximumPaletteColors = 8
    static let customLampCount = 108
    static let maximumCustomFrames = 32

    static let `default` = QuadCast2SEffectConfiguration(
        kind: .solid,
        palette: [PresetColor.purple.rgb, PresetColor.cyan.rgb],
        brightness: 100,
        speed: 0.35,
        axis: .around,
        direction: .forward,
        spread: 1,
        softness: 0.45,
        customColors: Array(
            repeating: PresetColor.purple.rgb,
            count: customLampCount
        ),
        customFrames: [
            Array(repeating: PresetColor.purple.rgb, count: customLampCount),
            Array(repeating: PresetColor.cyan.rgb, count: customLampCount)
        ],
        frameDuration: 0.5,
        frameTransition: .crossFade,
        framePlayback: .loop
    )

    init(
        kind: QuadCast2SEffectKind,
        palette: [RGBColor],
        brightness: Int,
        speed: Double,
        axis: QuadCast2SEffectAxis,
        direction: QuadCast2SEffectDirection,
        spread: Double,
        softness: Double,
        customColors: [RGBColor],
        customFrames: [[RGBColor]] = [],
        frameDuration: Double = 0.5,
        frameTransition: QuadCast2SFrameTransition = .crossFade,
        framePlayback: QuadCast2SFramePlayback = .loop
    ) {
        self.kind = kind
        self.palette = palette
        self.brightness = brightness
        self.speed = speed
        self.axis = axis
        self.direction = direction
        self.spread = spread
        self.softness = softness
        self.customColors = customColors
        self.customFrames = customFrames
        self.frameDuration = frameDuration
        self.frameTransition = frameTransition
        self.framePlayback = framePlayback
    }

    func normalized() -> QuadCast2SEffectConfiguration {
        var safePalette = Array(
            palette.prefix(Self.maximumPaletteColors).map { $0.clamped() }
        )
        if safePalette.isEmpty {
            safePalette = [PresetColor.purple.rgb]
        }
        while safePalette.count < kind.minimumPaletteCount {
            safePalette.append(safePalette.last ?? PresetColor.purple.rgb)
        }

        var safeCustom = Array(
            customColors.prefix(Self.customLampCount).map { $0.clamped() }
        )
        let fill = safePalette.first ?? PresetColor.purple.rgb
        if safeCustom.count < Self.customLampCount {
            safeCustom.append(
                contentsOf: repeatElement(
                    fill,
                    count: Self.customLampCount - safeCustom.count
                )
            )
        }

        var safeFrames = Array(customFrames.prefix(Self.maximumCustomFrames)).map { frame in
            var safeFrame = Array(
                frame.prefix(Self.customLampCount).map { $0.clamped() }
            )
            if safeFrame.count < Self.customLampCount {
                safeFrame.append(
                    contentsOf: repeatElement(
                        fill,
                        count: Self.customLampCount - safeFrame.count
                    )
                )
            }
            return safeFrame
        }
        if safeFrames.isEmpty {
            safeFrames = [safeCustom]
        }

        return QuadCast2SEffectConfiguration(
            kind: kind,
            palette: safePalette,
            brightness: max(0, min(100, brightness)),
            speed: max(0.05, min(3, speed)),
            axis: axis,
            direction: direction,
            spread: max(0.25, min(6, spread)),
            softness: max(0.05, min(1, softness)),
            customColors: safeCustom,
            customFrames: safeFrames,
            frameDuration: max(0.05, min(5, frameDuration)),
            frameTransition: frameTransition,
            framePlayback: framePlayback
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind, palette, brightness, speed, axis, direction
        case spread, softness, customColors
        case customFrames, frameDuration, frameTransition, framePlayback
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let customColors = try container.decodeIfPresent(
            [RGBColor].self,
            forKey: .customColors
        ) ?? defaults.customColors
        self.init(
            kind: try container.decodeIfPresent(QuadCast2SEffectKind.self, forKey: .kind)
                ?? defaults.kind,
            palette: try container.decodeIfPresent([RGBColor].self, forKey: .palette)
                ?? defaults.palette,
            brightness: try container.decodeIfPresent(Int.self, forKey: .brightness)
                ?? defaults.brightness,
            speed: try container.decodeIfPresent(Double.self, forKey: .speed)
                ?? defaults.speed,
            axis: try container.decodeIfPresent(QuadCast2SEffectAxis.self, forKey: .axis)
                ?? defaults.axis,
            direction: try container.decodeIfPresent(QuadCast2SEffectDirection.self, forKey: .direction)
                ?? defaults.direction,
            spread: try container.decodeIfPresent(Double.self, forKey: .spread)
                ?? defaults.spread,
            softness: try container.decodeIfPresent(Double.self, forKey: .softness)
                ?? defaults.softness,
            customColors: customColors,
            customFrames: try container.decodeIfPresent(
                [[RGBColor]].self,
                forKey: .customFrames
            ) ?? [customColors],
            frameDuration: try container.decodeIfPresent(
                Double.self,
                forKey: .frameDuration
            ) ?? defaults.frameDuration,
            frameTransition: try container.decodeIfPresent(
                QuadCast2SFrameTransition.self,
                forKey: .frameTransition
            ) ?? defaults.frameTransition,
            framePlayback: try container.decodeIfPresent(
                QuadCast2SFramePlayback.self,
                forKey: .framePlayback
            ) ?? defaults.framePlayback
        )
        self = normalized()
    }
}

enum QuadCast2SLampLayout {
    /// Hardware-verified 12-column × 9-row cylindrical layout. Runtime code
    /// interrogates report 3 and replaces this with live geometry; this copy
    /// keeps previews and offline tests accurate when no microphone is open.
    static let knownQuadCast2S: [QuadCast2SLamp] = {
        let xs: [UInt32] = [
            41_500, 34_500, 32_000, 34_500, 41_500, 51_000,
            60_500, 67_500, 70_000, 67_500, 60_500, 51_000
        ]
        let ys: [UInt32] = [
            66_600, 73_500, 83_000, 92_500, 99_500, 102_000,
            99_500, 92_500, 83_000, 73_500, 66_600, 64_000
        ]
        let zs: [UInt32] = [
            17_400, 27_800, 38_200, 48_600, 59_100,
            69_500, 79_900, 90_300, 100_700
        ]

        return (0..<108).map { rawID in
            let column = rawID / 9
            let slot = rawID % 9
            let row = column.isMultiple(of: 2) ? 8 - slot : slot
            return QuadCast2SLamp(
                id: UInt16(rawID),
                x: xs[column],
                y: ys[column],
                z: zs[row],
                updateLatencyMicroseconds: 5_000,
                purposes: 0x01,
                redLevelCount: 255,
                greenLevelCount: 255,
                blueLevelCount: 255,
                intensityLevelCount: 255,
                isProgrammable: true,
                inputBinding: 0
            )
        }
    }()

    /// UI grid coordinates use row 0 as the physical top of the microphone.
    static func lampID(column: Int, row: Int) -> Int {
        let safeColumn = max(0, min(11, column))
        let safeRow = max(0, min(8, row))
        let slot = safeColumn.isMultiple(of: 2) ? 8 - safeRow : safeRow
        return safeColumn * 9 + slot
    }
}
