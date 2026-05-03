//
//  BatterySparkline.swift
//  MacGenuity
//
//  Compact chart of recent battery percent. Falls back to a Path-drawn
//  sparkline on macOS 13 (Charts is technically macOS 13+ but we use the
//  raw Path approach so the entire UI works without importing Charts;
//  also avoids issues with empty data sets).
//

import SwiftUI

struct BatterySparkline: View {
    let samples: [BatterySample]
    var range: ClosedRange<Double> = 0...100
    var lineColor: Color = .accentColor
    var fillColor: Color = .accentColor.opacity(0.15)

    var body: some View {
        GeometryReader { geo in
            let usable = samples.suffix(120)  // last ~10h at 5-min cadence
            if usable.count >= 2 {
                let path = makePath(in: geo.size, samples: Array(usable))
                let fill = makeFill(in: geo.size, samples: Array(usable))
                ZStack {
                    fill.fill(fillColor)
                    path.stroke(lineColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
                .accessibilityLabel(accessibilityText(samples: Array(usable)))
            } else {
                Text("Collecting…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func point(_ sample: BatterySample, index: Int, count: Int, in size: CGSize) -> CGPoint {
        let x = count <= 1 ? size.width / 2 : size.width * CGFloat(index) / CGFloat(count - 1)
        let span = range.upperBound - range.lowerBound
        let yNorm = (Double(sample.percent) - range.lowerBound) / max(span, 0.0001)
        let y = size.height * (1.0 - CGFloat(min(max(yNorm, 0), 1)))
        return CGPoint(x: x, y: y)
    }

    private func makePath(in size: CGSize, samples: [BatterySample]) -> Path {
        var path = Path()
        for (i, sample) in samples.enumerated() {
            let p = point(sample, index: i, count: samples.count, in: size)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func makeFill(in size: CGSize, samples: [BatterySample]) -> Path {
        var path = Path()
        guard !samples.isEmpty else { return path }
        let first = point(samples[0], index: 0, count: samples.count, in: size)
        path.move(to: CGPoint(x: first.x, y: size.height))
        path.addLine(to: first)
        for (i, sample) in samples.enumerated().dropFirst() {
            path.addLine(to: point(sample, index: i, count: samples.count, in: size))
        }
        let lastIndex = samples.count - 1
        let last = point(samples[lastIndex], index: lastIndex, count: samples.count, in: size)
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.closeSubpath()
        return path
    }

    private func accessibilityText(samples: [BatterySample]) -> String {
        guard let first = samples.first, let last = samples.last else { return "No samples" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Battery from \(first.percent)% at \(formatter.string(from: first.date)) to \(last.percent)% at \(formatter.string(from: last.date))."
    }
}
