import SwiftUI

extension Color {
    /// The terracotta of the app icon.
    static let brand = Color(red: 0.86, green: 0.45, blue: 0.30)
}

/// The soft gradient the glass sits on: without something behind it, glass
/// reads as flat grey.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.65, 0.4], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: scheme == .dark ? [
                Color(red: 0.24, green: 0.13, blue: 0.10), Color(red: 0.16, green: 0.12, blue: 0.16), Color(red: 0.10, green: 0.11, blue: 0.16),
                Color(red: 0.20, green: 0.12, blue: 0.11), Color(red: 0.13, green: 0.12, blue: 0.15), Color(red: 0.09, green: 0.10, blue: 0.14),
                Color(red: 0.12, green: 0.10, blue: 0.11), Color(red: 0.10, green: 0.10, blue: 0.13), Color(red: 0.08, green: 0.09, blue: 0.12),
            ] : [
                Color(red: 1.00, green: 0.86, blue: 0.78), Color(red: 1.00, green: 0.93, blue: 0.88), Color(red: 0.93, green: 0.92, blue: 1.00),
                Color(red: 1.00, green: 0.91, blue: 0.86), Color(red: 0.99, green: 0.97, blue: 0.95), Color(red: 0.94, green: 0.95, blue: 1.00),
                Color(red: 0.99, green: 0.95, blue: 0.92), Color(red: 0.97, green: 0.96, blue: 0.97), Color(red: 0.95, green: 0.96, blue: 0.99),
            ]
        )
        .ignoresSafeArea()
    }
}

/// A job's state as a tinted disc with a symbol.
struct StatusBadge: View {
    let job: Job
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle()
                .fill(color.gradient)
                .shadow(color: color.opacity(0.35), radius: size / 6, y: size / 12)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.rotate, isActive: job.state == .running)
        }
        .frame(width: size, height: size)
    }

    private var symbol: String {
        switch job.state {
        case .running: return "arrow.trianglehead.2.clockwise"
        case .failed: return "xmark"
        case .succeeded: return job.enabled ? "checkmark" : "pause.fill"
        case .never: return job.enabled ? "clock" : "pause.fill"
        }
    }

    private var color: Color {
        switch job.state {
        case .running: return .blue
        case .failed: return .red
        case .succeeded: return job.enabled ? .green : .gray
        case .never: return job.enabled ? .brand : .gray
        }
    }
}

/// A small capsule: an icon and a short text.
struct Pill: View {
    let systemImage: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }
}

/// The last runs as dots, oldest left; hover one for its date and outcome.
struct RunDots: View {
    let runs: [RunStatus]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(runs.prefix(14).reversed().enumerated()), id: \.offset) { _, run in
                Circle()
                    .fill(color(run))
                    .frame(width: 8, height: 8)
                    .help(RunFormat.line(run))
            }
        }
    }

    private func color(_ run: RunStatus) -> Color {
        guard let code = run.exitCode else { return run.endedAt == nil ? .blue : .gray }
        return code == 0 ? .green : .red
    }
}

enum RunFormat {
    static func duration(_ run: RunStatus) -> String? {
        guard let end = run.endedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(run.startedAt))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(String(format: "%02d", seconds % 60)) s"
    }

    static func outcome(_ run: RunStatus) -> String {
        if run.skipped != nil { return tr("Skipped (budget)") }
        if run.timedOut == true { return tr("Timed out") }
        switch run.exitCode {
        case 0?: return "OK"
        case let code?: return tr("Failed (%@)", "\(code)")
        case nil: return run.endedAt == nil ? tr("Running") : tr("Interrupted")
        }
    }

    static func symbol(_ run: RunStatus?) -> String {
        if run?.skipped != nil { return "forward.end.circle" }
        if run?.timedOut == true { return "hourglass.circle" }
        switch run?.exitCode {
        case 0?: return "checkmark.circle.fill"
        case .some: return "xmark.circle.fill"
        case nil: return "circle.dashed"
        }
    }

    /// "$0.42", "$0.003"
    static func cost(_ dollars: Double) -> String {
        String(format: dollars > 0 && dollars < 0.01 ? "$%.3f" : "$%.2f", dollars)
    }

    /// "12k tokens"
    static func tokens(_ run: RunStatus) -> String? {
        guard run.inputTokens != nil || run.outputTokens != nil else { return nil }
        let total = (run.inputTokens ?? 0) + (run.outputTokens ?? 0)
        return tr("%@ tokens", total >= 1000 ? "\(total / 1000)k" : "\(total)")
    }

    /// "OK · 21 Oct 2026 at 16:08 · 34 s · $0.42 · 2 refused"
    static func line(_ run: RunStatus) -> String {
        [outcome(run), L10n.date(run.startedAt), duration(run), run.costUSD.map(cost),
         run.denied.flatMap { $0 > 0 ? tr("%@ refused", "\($0)") : nil }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
