import SwiftUI

let accent = Color(red: 1.0, green: 0.72, blue: 0.42)

/// The tutorial: round 1 with the screen on, test by test; round 2 with the
/// screen off, narrated through the glasses; then the results to share.
struct HomeView: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var results: ResultStore
    @State private var showSettings = false
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Find out what the glasses can do with this iPhone. Work through round 1 from top to bottom with the phone in your hand. Then start round 2, lock the phone and follow the voice in your glasses.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Round 1 · screen on") {
                    ForEach(Array(TestID.allCases.enumerated()), id: \.element) { index, test in
                        NavigationLink {
                            TestView(test: test)
                        } label: {
                            row(index + 1, test, results.result(test, .screenOn))
                        }
                    }
                }
                Section {
                    ScreenOffCard()
                    ForEach(TestID.allCases.filter { $0 != .connect }) { test in
                        let r = results.result(test, .screenOff)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: r.outcome.symbol).foregroundStyle(color(r.outcome))
                                Text(test.title)
                                Spacer()
                                Menu(r.outcome.rawValue) {
                                    ForEach(Outcome.allCases, id: \.self) { o in
                                        Button(o.rawValue) { results.set(test, .screenOff, o) }
                                    }
                                }.font(.footnote)
                            }
                            ForEach(r.measured.suffix(2), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } header: { Text("Round 2 · screen off") }
                Section("Results") {
                    ShareLink(item: results.report()) { Label("Share results", systemImage: "square.and.arrow.up") }
                    Button("Show log") { showLog = true }
                    // The whole log file, every run, not just this one.
                    ShareLink(item: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("stride-lab.log")) { Label("Share full log", systemImage: "doc.text") }
                    Button("Clear all results", role: .destructive) { results.reset() }
                }
            }
            .navigationTitle("Stride Lab")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showLog) { LogView() }
        }
        .tint(accent)
    }

    private func row(_ n: Int, _ test: TestID, _ r: TestResult) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(.headline).foregroundStyle(.secondary).frame(width: 20)
            Image(systemName: test.symbol).frame(width: 26)
            VStack(alignment: .leading) {
                Text(test.title)
                if let last = r.measured.last { Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Image(systemName: r.outcome.symbol).foregroundStyle(color(r.outcome))
        }
    }
}

func color(_ o: Outcome) -> Color {
    switch o {
    case .works: return .green
    case .partly: return .orange
    case .fails: return .red
    case .untested: return .secondary
    }
}

struct ScreenOffCard: View {
    @EnvironmentObject var lab: Lab

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Do round 1 first. Then tap Start, lock the phone and put it in your pocket. The glasses tell you what to do: talk, listen, pick Yes or No on the lens, look around, tap and pinch. It takes about three minutes. Unlock the phone afterwards to see what worked.")
                .font(.callout).foregroundStyle(.secondary)
            if lab.screenOffRunning {
                HStack {
                    ProgressView()
                    Text("Now: \(lab.screenOffStep)")
                    Spacer()
                    Button("Stop", role: .destructive) { lab.cancelScreenOffRound() }
                }
            } else {
                Button { lab.startScreenOffRound() } label: {
                    Label("Start screen-off round", systemImage: "lock.iphone").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(.vertical, 4)
    }
}

struct SettingsView: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var settings: LabSettings
    @EnvironmentObject var glasses: Glasses
    @Environment(\.dismiss) var dismiss
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://stt.example.com", text: $settings.sttURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(settings.hasKey ? "Key saved (type to replace)" : "API key", text: $key)
                    Button("Save key") { settings.setKey(key); key = "" }.disabled(key.isEmpty)
                    Button("Check server") { lab.checkStt() }
                    if !lab.sttHealth.isEmpty { Text(lab.sttHealth).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Speech-to-text server") } footer: {
                    Text("Easiest: on the PC run “npm run pair -- --lab” and scan the code with the Camera app. The key is kept in this iPhone's Keychain.")
                }
                Section("Glasses") {
                    LabeledContent("Registration", value: glasses.registration)
                    Button("Register again") { glasses.register() }
                    Button("Unregister", role: .destructive) { glasses.unregister() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct LogView: View {
    @EnvironmentObject var lab: Lab
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List(lab.lines.reversed()) { line in
                HStack(alignment: .top) {
                    Text(line.time).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(line.text).font(.caption)
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ShareLink(item: lab.lines.map { "\($0.time) \($0.text)" }.joined(separator: "\n"))
                Button("Done") { dismiss() }
            }
        }
    }
}
