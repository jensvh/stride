import SwiftUI

/// One test: the steps, the controls that run it, what the app measured, and
/// your verdict.
struct TestView: View {
    let test: TestID
    @EnvironmentObject var lab: Lab
    @EnvironmentObject var results: ResultStore
    @State private var note = ""

    var body: some View {
        let r = results.result(test, .screenOn)
        List {
            Section("Steps") {
                ForEach(Array(test.steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1).").foregroundStyle(accent).bold()
                        Text(s)
                    }
                }
            }
            Section("Test") { controls }
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
                    .onDisappear { if !note.isEmpty { results.note(test, .screenOn, note) } }
            }
        }
        .navigationTitle(test.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { note = r.note }
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

// MARK: - Per-test controls

struct ConnectControls: View {
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Registration", value: glasses.registration)
        LabeledContent("Glasses listed", value: "\(glasses.devices)")
        Text(glasses.deviceInfo).font(.footnote).foregroundStyle(glasses.connected ? .green : .orange)
        LabeledContent("Session", value: glasses.sessionState)
        Button("Register with the Meta AI app") { glasses.register() }
        Button("Open a session") {
            Task {
                let session = await glasses.ensureSession()
                results.measure(.connect, .screenOn, "registration \(glasses.registration), \(glasses.deviceInfo), session \(session == nil ? "failed: \(glasses.status)" : glasses.sessionState)")
            }
        }
        GlassesStatus()
    }
}

struct MicControls: View {
    @EnvironmentObject var audio: Audio
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Input", value: audio.input)
        LabeledContent("Output", value: audio.output)
        LabeledContent("Sample rate", value: audio.sampleRate > 0 ? "\(Int(audio.sampleRate)) Hz" : "—")
        Level(value: audio.level)
        if audio.running {
            Button("Stop", role: .destructive) {
                results.measure(.mic, .screenOn, "input \(audio.input), \(Int(audio.sampleRate)) Hz, peak \(String(format: "%.3f", audio.currentPeak))")
                audio.stop()
            }
        } else {
            Button("Start") { audio.resetPeak(); audio.start() }
        }
        if audio.running && !audio.viaGlasses {
            Text("Not listening through the glasses. Check they are connected in Bluetooth settings, then Stop and Start.")
                .font(.footnote).foregroundStyle(.orange)
        }
        ToolkitMic()
    }
}

/// The second route to the glasses' microphone: audio on the toolkit's camera
/// stream (Meta's sample app uses it because it keeps working in a pocket).
struct ToolkitMic: View {
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var results: ResultStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Second route: through the toolkit").font(.subheadline.bold())
            Text("The glasses' microphone as audio on the toolkit's camera stream. The Meta AI app asks for microphone access the first time.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        LabeledContent("Audio", value: glasses.micFrames > 0 ? "\(glasses.micFrames) blocks, \(Int(glasses.micRate)) Hz" : glasses.cameraState)
        Level(value: glasses.micLevel)
        if glasses.cameraState == "off" {
            Button("Start (toolkit)") { glasses.startCamera(raw: false, showFrames: false, mic: true) }
        } else {
            Button("Stop (toolkit)", role: .destructive) {
                results.measure(.mic, .screenOn, "toolkit route: \(glasses.micFrames) audio blocks, \(Int(glasses.micRate)) Hz, peak \(String(format: "%.3f", glasses.micPeak))")
                glasses.stopCamera()
            }
        }
        GlassesStatus()
    }
}

/// What the last glasses action is doing, or why it stopped.
struct GlassesStatus: View {
    @EnvironmentObject var glasses: Glasses

    var body: some View {
        if !glasses.status.isEmpty {
            Text(glasses.status).font(.footnote)
                .foregroundStyle(glasses.status.contains("fail") || glasses.status.contains("not ") || glasses.status.contains("No ") ? .orange : .secondary)
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
                stt.stop()
            }
        } else {
            Button("Start") { lab.startStt() }.disabled(!lab.sttReady)
        }
        Button("Clear text") { stt.clear() }
    }
}

struct SpeechControls: View {
    @EnvironmentObject var audio: Audio
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Output", value: audio.output)
        Button("Speak") {
            audio.say("Hello from Stride Lab. You should hear this in your glasses, not from the phone.")
            results.measure(.speech, .screenOn, "spoke through \(audio.output)")
        }
        Button("Beep") { audio.beep() }
        if audio.speaking { Text("Speaking…").font(.footnote).foregroundStyle(.secondary) }
    }
}

struct CameraControls: View {
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Camera", value: glasses.cameraState)
        LabeledContent("Frames", value: "\(glasses.frames) · \(String(format: "%.0f", glasses.fps)) fps")
        if glasses.previewing {
            FramePreviewView(preview: glasses.preview).frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 10))
        } else if let frame = glasses.frame {
            Image(uiImage: frame).resizable().scaledToFit().frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        if glasses.cameraState == "off" {
            Button("Start") { glasses.startCamera() }
            Button("Start uncompressed (needs Wi-Fi link)") { glasses.startCamera(raw: true) }
                .font(.footnote)
        } else {
            Button("Stop", role: .destructive) {
                results.measure(.camera, .screenOn, "\(glasses.frames) frames, about \(String(format: "%.0f", glasses.fps)) fps")
                glasses.stopCamera()
            }
        }
        GlassesStatus()
    }
}

struct PhotoControls: View {
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var results: ResultStore

    var body: some View {
        Button("Take photo") { glasses.takePhoto() }
        GlassesStatus()
        if let photo = glasses.photo {
            Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 10))
            LabeledContent("Size", value: "\(Int(photo.size.width * photo.scale)) × \(Int(photo.size.height * photo.scale))")
            if let ms = glasses.photoMs {
                LabeledContent("Took", value: "\(ms) ms")
                    .onAppear { results.measure(.photo, .screenOn, "photo \(Int(photo.size.width * photo.scale))×\(Int(photo.size.height * photo.scale)) after \(ms) ms") }
            }
        }
    }
}

struct DisplayControls: View {
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var display: GlassesDisplay
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Display", value: display.state)
        LabeledContent("Picked on the lens", value: display.choices.isEmpty ? "nothing yet" : display.choices.joined(separator: ", "))
        Button("Show card on the lens") {
            glasses.showCard(title: "Stride Lab", body: "Can you read this? Pick Yes or No with the Neural Band.")
        }
        Button("Show a longer text") {
            glasses.showCard(title: "Claude", body: "The tests pass. I changed two files: the relay client and its test. Want me to open a pull request?")
        }
        GlassesStatus()
        Button("Clear") {
            if !display.choices.isEmpty || display.sendMs != nil {
                results.measure(.display, .screenOn, "card sent in \(display.sendMs ?? -1) ms, picks: \(display.choices.joined(separator: ", "))")
            }
            display.clear()
        }
    }
}

struct GestureControls: View {
    @EnvironmentObject var glasses: Glasses
    @EnvironmentObject var display: GlassesDisplay
    @EnvironmentObject var audio: Audio
    @EnvironmentObject var results: ResultStore

    var body: some View {
        LabeledContent("Glasses inputs", value: display.inputsState)
        LabeledContent("Media buttons", value: audio.running ? "listening" : "off")
        Button("Start listening") {
            display.clearInputs()
            audio.clearMediaKeys()
            // Audio first: switching the glasses to the headset profile can
            // briefly end a toolkit session, so the inputs attach after it.
            audio.start { _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    glasses.startInputs()
                }
            }
        }
        GlassesStatus()
        if !display.inputs.isEmpty {
            ForEach(Array(display.inputs.suffix(10).enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
        }
        if !audio.mediaKeys.isEmpty {
            Text("Media buttons: \(audio.mediaKeys.joined(separator: ", "))").font(.footnote)
        }
        Button("Save what arrived") {
            results.measure(.gestures, .screenOn, "inputs: \(display.inputs.count), media buttons: \(audio.mediaKeys.joined(separator: ", ").isEmpty ? "none" : audio.mediaKeys.joined(separator: ", "))")
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
