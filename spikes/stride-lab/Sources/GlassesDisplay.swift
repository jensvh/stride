// No SwiftUI in this file: MWDATDisplay has its own Text, Button and Image.
import Combine
import Foundation
import MWDATCore
import MWDATDisplay
import MWDATInputs

/// Custom UI on the lens (MWDATDisplay) and glasses inputs (MWDATInputs).
@MainActor
final class GlassesDisplay: ObservableObject {
    @Published private(set) var state = "off"
    @Published private(set) var choices: [String] = []
    @Published private(set) var inputs: [String] = []
    @Published private(set) var inputsState = "off"
    @Published private(set) var sendMs: Int?

    var onLog: ((String) -> Void)?
    var onChoice: ((String) -> Void)?

    private var display: Display?
    private var inputsCapability: Inputs?
    private var tokens: [AnyListenerToken] = []
    private var inputsTask: Task<Void, Never>?

    // MARK: Display

    func show(on session: DeviceSession, title: String, body: String) async {
        do {
            if display == nil {
                let capability = try session.addDisplay()
                tokens.append(capability.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        self?.state = String(describing: state)
                        self?.onLog?("display: \(state)")
                    }
                })
                capability.start()
                display = capability
                for _ in 0..<25 {
                    if String(describing: capability.state).lowercased().contains("started") { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            guard let display else { return }
            let started = Date()
            try await display.send(card(title: title, body: body))
            sendMs = Int(Date().timeIntervalSince(started) * 1000)
            onLog?("display: card sent in \(sendMs ?? 0) ms")
        } catch {
            onLog?("display failed: \(error)")
        }
    }

    private func card(title: String, body: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 16, alignment: .start, crossAlignment: .start) {
            Text(title, style: .heading, color: .primary)
            Text(body, style: .body, color: .secondary)
            ButtonGroup(alignment: .start) {
                Button(label: "Yes", style: .primary, onClick: { [weak self] in
                    Task { @MainActor in self?.chose("Yes") }
                })
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
        tokens.removeAll()
        state = "off"
        stopInputs()
    }

    // MARK: Inputs (touchpad, Neural Band)

    func startInputs(on session: DeviceSession) {
        guard inputsCapability == nil else { return }
        do {
            guard let capability = try session.addInputs() else {
                inputsState = "not available"
                onLog?("inputs: not available on these glasses")
                return
            }
            inputsCapability = capability
            inputsState = "listening"
            onLog?("inputs: listening")
            inputsTask = Task { [weak self] in
                for await event in capability.events {
                    await MainActor.run {
                        let text = String(describing: event)
                        self?.inputs.append(text)
                        if (self?.inputs.count ?? 0) > 50 { self?.inputs.removeFirst() }
                        self?.onLog?("input: \(text)")
                    }
                }
                await MainActor.run { self?.inputsState = "ended" }
            }
        } catch {
            inputsState = "failed"
            onLog?("inputs failed: \(error)")
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
