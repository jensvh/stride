import SwiftUI

/// One test: what is open right now, the steps, the controls that run it,
/// what the app measured, and your verdict. Leaving the test stops what it
/// started.
struct TestView: View {
    let test: TestID
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var results: ResultStore
    @State private var note = ""

    var body: some View {
        let r = results.result(test, .screenOn)
        List {
            Section { StatusStrip() }
            Section("Steps") {
                ForEach(Array(test.steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1).").foregroundStyle(accent).bold()
                        Text(s)
                    }
                }
            }
            Section("Test") { controls }
                .disabled(lab.locked)
            if !r.measured.isEmpty {
                Section("Measured") {
                    ForEach(r.measured, id: \.self) { Text($0).font(.footnote) }
                }
            }
            Section("Your verdict") {
                Picker("Result", selection: Binding(get: { r.outcome }, set: { results.set(test, .screenOn, $0) })) {
                    ForEach([Outcome.works, .partly, .fails], id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                TextField("Note (optional)", text: $note, axis: .vertical)
                    .onSubmit { results.note(test, .screenOn, note) }
            }
        }
        .navigationTitle(test.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ResetMenu() }
        .onAppear { note = r.note }
        .onDisappear {
            if !note.isEmpty { results.note(test, .screenOn, note) }
            lab.leave(test)
        }
    }

    @ViewBuilder private var controls: some View {
        switch test {
        case .connect: ConnectControls()
        case .mic: MicControls()
        case .stt: SttControls()
        case .speech: SpeechControls()
        case .camera: CameraControls()
        case .photo: PhotoControls()
        case .display: DisplayControls()
        case .gestures: GestureControls()
        }
    }
}

// MARK: - Status and reset

func color(_ phase: Phase) -> Color {
    switch phase {
    case .off: return .secondary
    case .starting, .stopping: return .yellow
    case .on: return .green
    case .paused: return .orange
    case .failed: return .red
    }
}

/// What is open right now, the action that is running, the last event, and
/// what to do when something is wrong.
struct StatusStrip: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var display: GlassesDisplay
    @EnvironmentObject var audio: Audio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner = glasses.banner {
                Label(banner, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            }
            if let banner = lab.banner {
                Label(banner, systemImage: "lightbulb.fill").font(.footnote).foregroundStyle(.yellow)
            }
            HStack(spacing: 10) {
                dot("Registered", glasses.registered ? .on : .failed("no"))
                dot("Glasses", glasses.connected ? .on : .off)
                dot("Session", glasses.sessionPhase)
            }
            HStack(spacing: 10) {
                dot("Camera", glasses.cameraPhase)
                dot("Card", display.phase)
                dot("Gestures", display.inputsPhase)
                dot("Headset mic", audio.running ? .on : .off)
            }
            if let busy = glasses.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Working: \(busy)…").font(.footnote)
                    Spacer()
                    Button("Stop everything", role: .destructive) { lab.stopEverything() }
                        .font(.footnote).buttonStyle(.borderless)
                }
            } else if lab.screenOffRunning {
                Text("The screen-off round is running: \(lab.screenOffStep)").font(.footnote)
            }
            if !glasses.status.isEmpty {
                Text(glasses.status).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func dot(_ name: String, _ phase: Phase) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(phase)).frame(width: 8, height: 8)
            Text(name).font(.caption)
        }
    }
}

/// The way out of every stuck state.
struct ResetMenu: View {
    @EnvironmentObject var lab: Lab

    var body: some View {
        Menu {
            Button { lab.stopEverything() } label: { Label("Stop everything", systemImage: "stop.circle") }
            Button { lab.resetGlassesConnection() } label: { Label("Reset glasses connection", systemImage: "eyeglasses") }
            Button { lab.resetAudio() } label: { Label("Reset audio", systemImage: "speaker.slash") }
            Button(role: .destructive) { lab.fullReset() } label: { Label("Full reset", systemImage: "arrow.counterclockwise") }
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise.circle")
        }
    }
}

// MARK: - Per-test controls

struct ConnectControls: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Registration", value: glasses.registration)
        LabeledContent("Glasses listed", value: "\(glasses.devices)")
        Text(glasses.deviceInfo).font(.footnote).foregroundStyle(glasses.connected ? .green : .orange)
        LabeledContent("Session", value: glasses.sessionPhase.label)
        Button("Register with the Meta AI app") { glasses.register() }
        Button("Open a session") { lab.openSession() }
        Button("Start a new session") { lab.newSession() }
        if glasses.hasSession {
            Button("Close the session", role: .destructive) { lab.closeSession() }
        }
        Button("Save the state") {
            results.measure(.connect, .screenOn, "registration \(glasses.registration), \(glasses.deviceInfo), session \(glasses.sessionPhase.label)")
        }
    }
}

struct MicControls: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var audio: Audio
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Input", value: audio.input)
        LabeledContent("Output", value: audio.output)
        LabeledContent("Sample rate", value: audio.sampleRate > 0 ? "\(Int(audio.sampleRate)) Hz" : "—")
        Level(value: audio.level)
        if audio.running {
            Button("Save the level") {
                results.measure(.mic, .screenOn, "input \(audio.input), \(Int(audio.sampleRate)) Hz, peak \(String(format: "%.3f", audio.currentPeak))")
                audio.resetPeak()
            }
            Button("Turn the headset microphone off", role: .destructive) { lab.micOff() }
        } else {
            Button("Start") { lab.micStart() }
        }
        if audio.running && !audio.viaGlasses {
            Text("Not listening through the glasses. Check they are connected in Bluetooth settings, then turn the microphone off and on.")
                .font(.footnote).foregroundStyle(.orange)
        }
        Text("The headset microphone stays on for two minutes after use, so the glasses don't have to switch back and forth (that can make them refuse until restarted).")
            .font(.footnote).foregroundStyle(.secondary)
        ToolkitMic()
    }
}

/// The second route to the glasses' microphone: audio on the toolkit's camera
/// stream. It needs the headset microphone off.
struct ToolkitMic: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var results: ResultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Second route: through the toolkit").font(.subheadline.bold())
            Text("The glasses' microphone as audio on the toolkit's camera stream (the camera LED is on meanwhile). The headset microphone is turned off first. The Meta AI app asks for microphone access the first time.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        LabeledContent("Audio", value: glasses.micFrames > 0 ? "\(glasses.micFrames) blocks, \(Int(glasses.micRate)) Hz" : glasses.cameraPhase.label)
        Level(value: glasses.micLevel)
        if glasses.cameraOpen {
            Button("Stop (toolkit)", role: .destructive) {
                results.measure(.mic, .screenOn, "toolkit route: \(glasses.micFrames) audio blocks, \(Int(glasses.micRate)) Hz, peak \(String(format: "%.3f", glasses.micPeak))")
                lab.toolkitMicStop()
            }
        } else {
            Button("Start (toolkit)") { lab.toolkitMicStart() }
        }
    }
}

struct SttControls: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var stt: SttClient
    @EnvironmentObject var audio: Audio
    @EnvironmentObject var settings: LabSettings
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Server", value: URL(string: settings.sttURL)?.host ?? "not set")
        LabeledContent("Key", value: settings.hasKey ? "saved" : "missing")
        Button("Check server") { lab.checkStt() }
        if !lab.sttHealth.isEmpty { Text(lab.sttHealth).font(.footnote).foregroundStyle(.secondary) }
        LabeledContent("Stream", value: stt.state)
        Level(value: audio.level)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(stt.finals.suffix(6).enumerated()), id: \.offset) { Text($0.element) }
            if !stt.partial.isEmpty { Text(stt.partial).foregroundStyle(.secondary) }
        }
        if stt.isOn {
            Button("Stop", role: .destructive) {
                if let ms = stt.lastLatencyMs { results.measure(.stt, .screenOn, "last: “\(stt.finals.last ?? "")”, server \(ms) ms") }
                lab.sttStop()
            }
        } else {
            Button("Start") { lab.sttStart() }.disabled(!lab.sttReady)
        }
        Button("Clear text") { stt.clear() }
    }
}

struct SpeechControls: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var audio: Audio
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Output", value: audio.output)
        Button("Speak") {
            lab.speakTest()
            results.measure(.speech, .screenOn, "spoke through \(audio.output)")
        }
        Button("Beep") { lab.beepTest() }
        if audio.speaking {
            Text("Speaking…").font(.footnote).foregroundStyle(.secondary)
        }
        if glasses.cameraOpen {
            Text("The camera is running: the glasses mute app sound meanwhile. Speak closes it first.")
                .font(.footnote).foregroundStyle(.orange)
        }
        Text("If you hear nothing after using the camera, that is a known glasses bug (Meta, ios#256): tap Reset → Reset audio, or switch the glasses off and on.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

struct CameraControls: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Camera", value: glasses.cameraPhase.label)
        LabeledContent("Frames", value: "\(glasses.frames) · \(String(format: "%.0f", glasses.fps)) fps")
        if glasses.previewing {
            FramePreviewView(preview: glasses.preview).frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 10))
        } else if let frame = glasses.frame {
            Image(uiImage: frame).resizable().scaledToFit().frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        if glasses.cameraOpen {
            Button("Stop", role: .destructive) {
                results.measure(.camera, .screenOn, "\(glasses.frames) frames, about \(String(format: "%.0f", glasses.fps)) fps")
                lab.cameraStop()
            }
        } else {
            Button("Start") { lab.cameraStart() }
            Button("Start uncompressed (needs the Wi-Fi link)") { lab.cameraStart(raw: true) }
                .font(.footnote)
        }
    }
}

struct PhotoControls: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var results: ResultStore

    var body: some View {
        Button("Take photo") { lab.photo() }
        Text("The camera is opened for the photo and closed again afterwards.")
            .font(.footnote).foregroundStyle(.secondary)
        if let photo = glasses.photo {
            Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 10))
            LabeledContent("Size", value: "\(Int(photo.size.width * photo.scale)) × \(Int(photo.size.height * photo.scale))")
            if let ms = glasses.photoMs {
                LabeledContent("Took", value: "\(ms) ms")
                Button("Save") {
                    results.measure(.photo, .screenOn, "photo \(Int(photo.size.width * photo.scale))×\(Int(photo.size.height * photo.scale)) after \(ms) ms")
                }
            }
        }
    }
}

struct DisplayControls: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var display: GlassesDisplay
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Card", value: display.phase.label)
        LabeledContent("Picked on the lens", value: display.choices.isEmpty ? "nothing yet" : display.choices.suffix(8).joined(separator: ", "))
        Button("Show card on the lens") {
            lab.showCard(title: "Stride Lab", body: "Can you read this? Pick Yes or No with the Neural Band.")
        }
        Button("Show a longer text") {
            lab.showCard(title: "Claude", body: "The tests pass. I changed two files: the relay client and its test. Want me to open a pull request?")
        }
        Button("Reopen on the lens (new session)") {
            lab.showCard(title: "Stride Lab", body: "Back on the lens. Pick Yes or No.", reopen: true)
        }
        if display.isOpen {
            Button("Close the card", role: .destructive) { lab.closeCard() }
        }
        Button("Save") {
            results.measure(.display, .screenOn, "card sent in \(display.sendMs ?? -1) ms, picks: \(display.choices.isEmpty ? "none" : display.choices.joined(separator: ", "))")
            display.clearChoices()
        }
    }
}

struct GestureControls: View {
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var display: GlassesDisplay
    @EnvironmentObject var audio: Audio
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Glasses inputs", value: display.inputsPhase.label)
        LabeledContent("Media buttons", value: audio.running ? "listening" : "only with the headset microphone on")
        if display.inputsOpen {
            Button("Stop listening", role: .destructive) { lab.gesturesStop() }
        } else {
            Button("Start: all gestures to the phone") { lab.gesturesStart(withCard: false) }
            Button("Start: with a card on the lens") { lab.gesturesStart(withCard: true) }
        }
        if !display.inputs.isEmpty || display.drags > 0 {
            ForEach(Array(display.inputs.suffix(10).enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
            if display.drags > 0 { Text("\(display.drags) drag events").font(.caption) }
        }
        if !display.choices.isEmpty {
            Text("Picked on the card: \(display.choices.suffix(6).joined(separator: ", "))").font(.footnote)
        }
        if !audio.mediaKeys.isEmpty {
            Text("Media buttons: \(audio.mediaKeys.joined(separator: ", "))").font(.footnote)
        }
        Button("Save what arrived") {
            let keys = audio.mediaKeys.joined(separator: ", ")
            results.measure(.gestures, .screenOn, "inputs: \(display.inputs.count), drags: \(display.drags), card picks: \(display.choices.count), media buttons: \(keys.isEmpty ? "none" : keys)")
        }
    }
}

struct Level: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(.green).frame(width: geo.size.width * value)
            }
        }.frame(height: 10)
    }
}
