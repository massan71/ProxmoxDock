import Charts
import SwiftUI

/// One chart: one or more series read from RRD samples.
struct ChartSpec: Identifiable {
    struct Series {
        var name: String
        var keys: [String]          // first available field per sample
        var scale: Double = 1       // e.g. 100 for fractions shown as %
    }
    enum Unit { case percent, bytes, bytesPerSecond, plain }

    var title: String
    var series: [Series]
    var unit: Unit
    /// Field holding the maximum for the Y axis (e.g. memtotal), if any
    var maxKey: [String] = []
    var id: String { title }

    func format(_ v: Double) -> String {
        switch unit {
        case .percent: return String(format: "%.0f%%", v)
        case .bytes: return Fmt.bytes(v)
        case .bytesPerSecond: return "\(Fmt.bytes(v))/s"
        case .plain: return String(format: "%.2f", v)
        }
    }

    static func specs(for kind: ResourceTarget.Kind) -> [ChartSpec] {
        if kind == .node {
            return [
                ChartSpec(title: "CPU", series: [Series(name: "CPU", keys: ["cpu"], scale: 100),
                                                 Series(name: "IO wait", keys: ["iowait"], scale: 100)], unit: .percent),
                ChartSpec(title: "Load average", series: [Series(name: "Load", keys: ["loadavg"])], unit: .plain),
                ChartSpec(title: "Memory", series: [Series(name: "Used", keys: ["memused", "mem"])], unit: .bytes,
                          maxKey: ["memtotal", "maxmem"]),
                ChartSpec(title: "Network", series: [Series(name: "In", keys: ["netin"]), Series(name: "Out", keys: ["netout"])],
                          unit: .bytesPerSecond),
            ]
        }
        return [
            ChartSpec(title: "CPU", series: [Series(name: "CPU", keys: ["cpu"], scale: 100)], unit: .percent),
            ChartSpec(title: "Memory", series: [Series(name: "Used", keys: ["mem", "memused"])], unit: .bytes, maxKey: ["maxmem", "memtotal"]),
            ChartSpec(title: "Network", series: [Series(name: "In", keys: ["netin"]), Series(name: "Out", keys: ["netout"])],
                      unit: .bytesPerSecond),
            ChartSpec(title: "Disk I/O", series: [Series(name: "Read", keys: ["diskread"]), Series(name: "Write", keys: ["diskwrite"])],
                      unit: .bytesPerSecond),
        ]
    }
}

private struct ChartPoint: Identifiable {
    var time: Date
    var series: String
    var value: Double
    var id: String { "\(series)-\(time.timeIntervalSince1970)" }
}

/// A titled chart card with the latest value.
struct PerformanceChart: View {
    let spec: ChartSpec
    let points: [RRDPoint]

    var body: some View {
        let data = spec.series.flatMap { s in
            points.compactMap { p in p.value(s.keys).map { ChartPoint(time: p.time, series: s.name, value: $0 * s.scale) } }
        }
        let maxValue = spec.unit == .percent ? 100 : points.compactMap { p in spec.maxKey.lazy.compactMap { p.values[$0] }.first }.max()
        let latest = spec.series.compactMap { s -> String? in
            guard let v = points.last(where: { $0.value(s.keys) != nil })?.value(s.keys) else { return nil }
            return spec.series.count > 1 ? "\(s.name) \(spec.format(v * s.scale))" : spec.format(v * s.scale)
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.title).font(.headline)
                Spacer()
                Text(latest.joined(separator: " · ")).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            if data.isEmpty {
                Text("No data").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart(data) { p in
                    AreaMark(x: .value("Time", p.time), y: .value(spec.title, p.value), stacking: .unstacked)
                        .foregroundStyle(by: .value("Series", p.series))
                        .opacity(0.15)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.time), y: .value(spec.title, p.value))
                        .foregroundStyle(by: .value("Series", p.series))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...max(maxValue ?? 0, data.map(\.value).max() ?? 1, spec.unit == .percent ? 1 : 0.0001))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(spec.format(v)).font(.caption2) }
                        }
                    }
                }
                .chartLegend(spec.series.count > 1 ? .visible : .hidden)
                .frame(height: 150)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

/// Grid of performance charts for one node, VM or container.
struct PerformanceCharts: View {
    let kind: ResourceTarget.Kind
    let points: [RRDPoint]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14)], spacing: 14) {
            ForEach(ChartSpec.specs(for: kind)) { PerformanceChart(spec: $0, points: points) }
        }
    }
}

/// Window with the performance history of a node, VM or container.
struct PerformanceWindow: View {
    let target: ResourceTarget
    @EnvironmentObject var store: Store
    @State private var timeframe = RRDTimeframe.hour
    @State private var points: [RRDPoint] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
                PerformanceCharts(kind: target.kind, points: points)
                Text("Averages from Proxmox's history (RRD). Refreshed every minute.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("Performance – \(target.title)")
        .navigationSubtitle(loading ? "Loading…" : "")
        .toolbar {
            ToolbarItem {
                Picker("Timeframe", selection: $timeframe) {
                    ForEach(RRDTimeframe.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        // Reloads when the timeframe changes, and every minute while the window is open
        .task(id: timeframe) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            points = try await store.api.rrd(target, timeframe: timeframe)
            error = nil
        } catch APIError.http(403, _) {
            error = "The API token needs \(target.kind == .node ? "Sys.Audit on /nodes/\(target.node)" : "VM.Audit on /vms/\(target.vmid ?? 0)") to read the history."
        } catch {
            self.error = "Could not load the history: \(error.localizedDescription)"
        }
    }
}
