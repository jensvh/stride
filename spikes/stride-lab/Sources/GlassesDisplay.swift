// No SwiftUI in this file: MWDATDisplay has its own Text, Button and Image.
import Combine
import Foundation
import MWDATCore
import MWDATDisplay
import MWDATInputs

/// Custom UI on the lens (MWDATDisplay) and glasses inputs (MWDATInputs).
///
/// Neither capability waits for the glasses the way the camera does: asked for
/// while the glasses are still arriving, they fail once and never retry. So both
/// are attached with patience: asked again every second for up to 15 seconds.
@MainActor
final class GlassesDisplay: ObservableObject {
    @Published private(set) var state = "off"
    @Published private(set) var choices: [String] = []
    @Published private(set) var inputs: [String] = []
    @Published private(set) var inputsState = "off"
    @Published private(set) var sendMs: Int?
    private(set) var lastError = ""

    var onLog: ((String) -> Void)?
    var onChoice: ((String) -> Void)?

    private var display: Display?
    private var inputsCapability: Inputs?
    private var tokens: [any AnyListenerToken] = []
    private var inputsTask: Task<Void, Never>?

    // MARK: Display

    /// Shows a card with Yes/No buttons. Returns false (with lastError) if the
    /// display could not be reached.
    func show(on session: DeviceSession, title: String, body: String) async -> Bool {
        guard let display = await attachDisplay(to: session) else { return false }
        do {
            let started = Date()
            try await display.send(card(title: title, body: body))
            sendMs = Int(Date().timeIntervalSince(started) * 1000)
            onLog?("display: card sent in \(sendMs ?? 0) ms")
            return true
        } catch {
            lastError = "sending the card failed: \(error)"
            onLog?("display: \(lastError)")
            return false
        }
    }

    private func attachDisplay(to session: DeviceSession) async -> Display? {
        if let display, display.state == .started { return display }
        if let display { display.stop(); self.display = nil }
        var lastFailure = ""
        for attempt in 1...15 {
            do {
                let capability = try session.addDisplay()
                tokens.append(capability.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        self?.state = String(describing: state)
                        self?.onLog?("display: \(state)")
                    }
                })
                display = capability
                capability.start()
                for _ in 0..<40 where capability.state != .started {
                    try? await Task.sleep(nanoseconds: 125_000_000)
                }
                state = String(describing: capability.state)
                if capability.state == .started {
                    onLog?("display: started (attempt \(attempt))")
                    return capability
                }
                lastFailure = "the display did not start (\(capability.state))"
                capability.stop()
                display = nil
            } catch {
                lastFailure = "\(error)"
            }
            onLog?("display: attempt \(attempt) failed: \(lastFailure)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        lastError = "could not open the display: \(lastFailure)"
        return nil
    }

    private func card(title: String, body: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 16, alignment: .start, crossAlignment: .start) {
            Text(title, style: .heading, color: .primary)
            Text(body, style: .body, color: .secondary)
            ButtonGroup(alignment: .start) {
                Button(label: "Yes", style: .primary, onClick: { [weak self] in
                    Task { @MainActor in self?.chose("Yes") }
                }).actionRole(.primary)
                Button(label: "No", style: .secondary, onClick: { [weak self] in
                    Task { @MainActor in self?.chose("No") }
                })
            }
        }
    }

    private func chose(_ choice: String) {
        choices.append(choice)
        onLog?("display: you picked \(choice) on the lens")
        onChoice?(choice)
    }

    func clear() {
        choices = []
        guard let display else { return }
        Task { [weak self] in
            do { try await display.clearDisplay() } catch { self?.onLog?("display clear failed: \(error)") }
        }
    }

    func stop() {
        display?.stop()
        display = nil
        let old = tokens
        tokens = []
        Task { for token in old { await token.cancel() } }
        state = "off"
        stopInputs()
    }

    // MARK: Inputs (touchpad, Neural Band, buttons)

    /// Returns false (with lastError) if the inputs could not be attached.
    func startInputs(on session: DeviceSession) async -> Bool {
        if inputsCapability != nil { return true }
        var lastFailure = ""
        for attempt in 1...15 {
            do {
                guard let capability = try session.addInputs() else {
                    lastError = "these glasses offer no inputs to the toolkit"
                    inputsState = "not available"
                    return false
                }
                inputsCapability = capability
                inputsState = "listening"
                onLog?("inputs: listening (attempt \(attempt)), sources \(capability.configuration.sources.map { "\($0)" }.sorted().joined(separator: ", "))")
                tokens.append(capability.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        self?.inputsState = String(describing: state)
                        self?.onLog?("inputs: \(state)")
                    }
                })
                tokens.append(capability.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in self?.onLog?("inputs error: \(error)") }
                })
                inputsTask = Task { [weak self] in
                    for await event in capability.events {
                        let text = Self.describe(event)
                        self?.inputs.append(text)
                        if (self?.inputs.count ?? 0) > 50 { self?.inputs.removeFirst() }
                        self?.onLog?("input: \(text)")
                    }
                    self?.inputsState = "ended"
                }
                return true
            } catch {
                lastFailure = "\(error)"
                onLog?("inputs: attempt \(attempt) failed: \(lastFailure)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        lastError = "could not attach the inputs: \(lastFailure)"
        inputsState = "failed"
        return false
    }

    private static func describe(_ event: InputEvent) -> String {
        switch event {
        case .nav(let direction, let source, _): return "swipe \(direction) (\(source))"
        case .select(let source, _): return "select (\(source))"
        case .back(let source, _): return "back (\(source))"
        case .button(let type, let source, _): return "button \(type) (\(source))"
        case .capture(let type, let source, _): return "capture \(type) (\(source))"
        default: return "\(event)"
        }
    }

    func stopInputs() {
        inputsTask?.cancel()
        inputsTask = nil
        inputsCapability = nil
        if inputsState != "off" { inputsState = "off" }
    }

    func clearInputs() { inputs = [] }
}
