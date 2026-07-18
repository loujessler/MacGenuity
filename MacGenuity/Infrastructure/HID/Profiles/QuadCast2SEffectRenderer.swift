//
//  QuadCast2SEffectRenderer.swift
//  MacGenuity
//
//  Pure spatial effect renderer for a cylindrical HID LampArray. The output
//  is one RGBI value per physical lamp and contains no timing or IOKit code.
//

import Foundation

enum QuadCast2SEffectRenderer {
    static func render(
        configuration source: QuadCast2SEffectConfiguration,
        lamps: [QuadCast2SLamp],
        elapsedTime: TimeInterval
    ) -> [QuadCast2SLampValue] {
        guard !lamps.isEmpty else { return [] }
        let configuration = source.normalized()
        let palette = configuration.palette
        let movement = elapsedTime
            * configuration.speed
            * configuration.direction.multiplier
        let maximumIntensity = Double(configuration.brightness * 255) / 100

        let minX = Double(lamps.map(\.x).min() ?? 0)
        let maxX = Double(lamps.map(\.x).max() ?? 1)
        let minY = Double(lamps.map(\.y).min() ?? 0)
        let maxY = Double(lamps.map(\.y).max() ?? 1)
        let minZ = Double(lamps.map(\.z).min() ?? 0)
        let maxZ = Double(lamps.map(\.z).max() ?? 1)
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let zSpan = max(1, maxZ - minZ)
        let frameSample = frameSample(
            for: configuration,
            elapsedTime: elapsedTime
        )

        return lamps.map { lamp in
            let around = wrapped(
                atan2(
                    Double(lamp.y) - centerY,
                    Double(lamp.x) - centerX
                ) / (2 * .pi)
            )
            let vertical = (Double(lamp.z) - minZ) / zSpan
            let coordinate: Double
            switch configuration.axis {
            case .around:
                coordinate = around
            case .vertical:
                coordinate = vertical
            case .diagonal:
                coordinate = wrapped(around + vertical)
            }

            let color: RGBColor
            let intensityScale: Double
            switch configuration.kind {
            case .solid:
                color = palette[0]
                intensityScale = 1

            case .colorCycle:
                color = sample(palette: palette, at: movement)
                intensityScale = 1

            case .gradient:
                color = sample(
                    palette: palette,
                    at: coordinate * configuration.spread + movement
                )
                intensityScale = 1

            case .spectrum:
                color = hsv(
                    hue: coordinate * configuration.spread + movement,
                    saturation: 1,
                    value: 1
                )
                intensityScale = 1

            case .wave:
                let phase = coordinate * configuration.spread + movement
                color = sample(palette: palette, at: phase)
                intensityScale = 0.12 + 0.88 * sine01(phase)

            case .orbit:
                let position = wrapped(coordinate * configuration.spread)
                let head = wrapped(movement)
                let distance = circularDistance(position, head)
                let width = 0.025 + configuration.softness * 0.22
                let glow = exp(-pow(distance / width, 2))
                color = interpolate(
                    palette.last ?? palette[0],
                    palette[0],
                    amount: glow
                )
                intensityScale = 0.04 + 0.96 * glow

            case .breathing:
                color = palette[0]
                intensityScale = 0.06 + 0.94 * sine01(movement)

            case .sparkle:
                let seedA = unitHash(UInt64(lamp.id) &* 0x9E37_79B9)
                let seedB = unitHash(UInt64(lamp.id) &* 0x85EB_CA6B &+ 0xC2B2_AE35)
                let localPhase = elapsedTime
                    * configuration.speed
                    * (0.65 + seedB * 1.7)
                    + seedA
                let pulse = max(0, sin(localPhase * 2 * .pi))
                let exponent = 3 + (1 - configuration.softness) * 11
                let sparkle = pow(pulse, exponent)
                let paletteIndex = min(
                    palette.count - 1,
                    Int(floor(seedB * Double(palette.count)))
                )
                color = palette[paletteIndex]
                intensityScale = 0.035 + 0.965 * sparkle

            case .custom:
                let id = Int(lamp.id)
                color = id < configuration.customColors.count
                    ? configuration.customColors[id]
                    : palette[0]
                intensityScale = 1

            case .frameAnimator:
                let id = Int(lamp.id)
                guard let frameSample,
                      configuration.customFrames[frameSample.current].indices.contains(id)
                else {
                    color = palette[0]
                    intensityScale = 1
                    break
                }
                let current = configuration.customFrames[frameSample.current][id]
                if configuration.frameTransition == .crossFade,
                   configuration.customFrames[frameSample.next].indices.contains(id)
                {
                    color = interpolate(
                        current,
                        configuration.customFrames[frameSample.next][id],
                        amount: frameSample.progress
                    )
                } else {
                    color = current
                }
                intensityScale = 1
            }

            return QuadCast2SLampValue(
                lampID: lamp.id,
                color: color.clamped(),
                intensity: Int((maximumIntensity * intensityScale).rounded())
            ).normalized()
        }
    }

    static func sample(palette: [RGBColor], at rawPosition: Double) -> RGBColor {
        guard let first = palette.first else { return PresetColor.purple.rgb }
        guard palette.count > 1 else { return first.clamped() }

        let scaled = wrapped(rawPosition) * Double(palette.count)
        let lower = Int(floor(scaled)) % palette.count
        let upper = (lower + 1) % palette.count
        return interpolate(
            palette[lower],
            palette[upper],
            amount: scaled - floor(scaled)
        )
    }

    static func interpolate(
        _ first: RGBColor,
        _ second: RGBColor,
        amount: Double
    ) -> RGBColor {
        let t = max(0, min(1, amount))
        let a = first.clamped()
        let b = second.clamped()
        return RGBColor(
            red: Int((Double(a.red) + Double(b.red - a.red) * t).rounded()),
            green: Int((Double(a.green) + Double(b.green - a.green) * t).rounded()),
            blue: Int((Double(a.blue) + Double(b.blue - a.blue) * t).rounded())
        ).clamped()
    }

    static func hsv(hue: Double, saturation: Double, value: Double) -> RGBColor {
        let h = wrapped(hue) * 6
        let sector = Int(floor(h))
        let fraction = h - floor(h)
        let s = max(0, min(1, saturation))
        let v = max(0, min(1, value))
        let p = v * (1 - s)
        let q = v * (1 - fraction * s)
        let t = v * (1 - (1 - fraction) * s)
        let channels: (Double, Double, Double)
        switch sector % 6 {
        case 0: channels = (v, t, p)
        case 1: channels = (q, v, p)
        case 2: channels = (p, v, t)
        case 3: channels = (p, q, v)
        case 4: channels = (t, p, v)
        default: channels = (v, p, q)
        }
        return RGBColor(
            red: Int((channels.0 * 255).rounded()),
            green: Int((channels.1 * 255).rounded()),
            blue: Int((channels.2 * 255).rounded())
        ).clamped()
    }

    private static func wrapped(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    private static func sine01(_ phase: Double) -> Double {
        (sin(wrapped(phase) * 2 * .pi - .pi / 2) + 1) / 2
    }

    private static func circularDistance(_ first: Double, _ second: Double) -> Double {
        let direct = abs(first - second)
        return min(direct, 1 - direct)
    }

    private struct FrameSample {
        let current: Int
        let next: Int
        let progress: Double
    }

    private static func frameSample(
        for configuration: QuadCast2SEffectConfiguration,
        elapsedTime: TimeInterval
    ) -> FrameSample? {
        let count = configuration.customFrames.count
        guard count > 0 else { return nil }
        guard count > 1 else {
            return FrameSample(current: 0, next: 0, progress: 0)
        }

        let position = max(0, elapsedTime) / configuration.frameDuration
        let wholeStep = Int(floor(position))
        let progress = position - floor(position)
        let direction = configuration.direction == .forward ? 1 : -1

        func index(for step: Int) -> Int {
            switch configuration.framePlayback {
            case .loop:
                return positiveModulo(step, count)
            case .pingPong:
                let cycleLength = (count - 1) * 2
                let position = positiveModulo(step, cycleLength)
                return position < count ? position : cycleLength - position
            }
        }

        return FrameSample(
            current: index(for: wholeStep * direction),
            next: index(for: (wholeStep + 1) * direction),
            progress: progress
        )
    }

    private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder < 0 ? remainder + modulus : remainder
    }

    private static func unitHash(_ value: UInt64) -> Double {
        var x = value
        x ^= x >> 33
        x &*= 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 33
        x &*= 0xC4CE_B9FE_1A85_EC53
        x ^= x >> 33
        return Double(x & 0x00FF_FFFF) / Double(0x0100_0000)
    }
}
