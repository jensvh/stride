import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var probe: Probe

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(probe.running ? "Stop" : "Start listening") {
                        if probe.running { probe.stop() } else { probe.start() }
                    }
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)

                    if probe.running {
                        ProgressView(value: probe.level)
                        Text(probe.heard.isEmpty ? "Say something…" : probe.heard)
                            .foregroundStyle(probe.heard.isEmpty ? .secondary : .primary)
                    }
                }

                Section("What we need to know") {
                    ForEach(probe.findings) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: icon(finding.verdict))
                                .foregroundStyle(color(finding.verdict))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.id)
                                Text(finding.answer)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Options") {
                    if !probe.inputs.isEmpty {
                        Picker("Microphone", selection: Binding(
                            get: { probe.selectedInput },
                            set: { probe.choose(input: $0) }
                        )) {
                            ForEach(probe.inputs) { input in
                                Text(input.label).tag(input.id)
                            }
                        }
                    }
                    Toggle("Repeat what I said", isOn: $probe.echo)
                    Button("Speak a test sentence") { probe.speakTest() }
                        .disabled(!probe.running)
                    LabeledContent("PC link", value: probe.relayStatus)
                }

                Section("Log") {
                    ForEach(probe.lines.suffix(150).reversed()) { line in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.time)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            Text(line.text)
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Stride probe")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: probe.report())
                }
            }
        }
    }

    private func icon(_ verdict: Finding.Verdict) -> String {
        switch verdict {
        case .unknown: return "circle.dotted"
        case .good: return "checkmark.circle.fill"
        case .bad: return "xmark.circle.fill"
        }
    }

    private func color(_ verdict: Finding.Verdict) -> Color {
        switch verdict {
        case .unknown: return .secondary
        case .good: return .green
        case .bad: return .red
        }
    }
}
