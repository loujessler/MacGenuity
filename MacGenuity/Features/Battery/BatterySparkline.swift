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
            if let first = samples.first, let last = samples.last, last.date > first.date {
                let path = makePath(in: geo.size, start: first.date, end: last.date)
                ZStack {
                    Path { fill in
                        fill.addPath(path)
                        fill.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        fill.addLine(to: CGPoint(x: 0, y: geo.size.height))
                        fill.closeSubpath()
                    }.fill(fillColor)
                    path.stroke(lineColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText(samples: samples))
            } else {
                Text("Collecting…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func makePath(in size: CGSize, start: Date, end: Date) -> Path {
        let duration = end.timeIntervalSince(start)
        let span = range.upperBound - range.lowerBound
        var path = Path()
        for (index, sample) in samples.enumerated() {
            let x = size.width * CGFloat(sample.date.timeIntervalSince(start) / duration)
            let fraction = (Double(sample.percent) - range.lowerBound) / max(span, 0.0001)
            let point = CGPoint(x: x, y: size.height * (1 - CGFloat(min(max(fraction, 0), 1))))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
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
