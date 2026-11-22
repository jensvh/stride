// No SwiftUI in this file: MWDATDisplay has its own Text, Button and Image.
import Combine
import Foundation
import MWDATCore
import MWDATDisplay
import MWDATInputs

/// Custom UI on the lens (MWDATDisplay) and glasses inputs (MWDATInputs).
///
/// - Neither waits for the glasses the way the camera does: asked for while
///   the glasses are still arriving, they fail once. Both are retried.
/// - Every card has a Close button: on real glasses the back gesture closes
///   the app on the glasses instead of reaching the app (Meta, ios#349).
/// - Closing is confirmed: clear, stop, wait for stopped; inputs are removed.
/// - Each instance has a generation number; callbacks from an older one are
///   ignored.
@MainActor
final class GlassesDisplay: ObservableObject {
    @Published private(set) var phase: Phase = .off { didSet { if phase != oldValue { resourcesChanged?() } } }
    @Published private(set) var inputsPhase: Phase = .off { didSet { if inputsPhase != oldValue { resourcesChanged?() } } }
    @Published private(set) var choices: [String] = []
    @Published private(set) var inputs: [String] = []
    @Published private(set) var drags = 0
    @Published private(set) var sendMs: Int?
    private(set) var lastError = ""
    /// Set when the session refuses a new display or inputs (already active):
    /// only a new session can bring them back.
    private(set) var needsNewSession = false
    private(set) var lastCardAt: Date?
    /// A card was shown in this session (it may have been closed on the
    /// glasses since, which the toolkit doesn't report).
    private(set) var usedInSession = false

    var onLog: ((String) -> Void)?
    var onChoice: ((String) -> Void)?
    var onClosePressed: (() -> Void)?
    var resourcesChanged: (() -> Void)?

    private var display: Display?
    private var displayGen = 0
    private var displayTokens: [any AnyListenerToken] = []
    private var closingDisplay = false

    private var inputsCapability: Inputs?
    private var inputsGen = 0
    private var inputsTokens: [any AnyListenerToken] = []
    private var inputsReader: Task<Void, Never>?
    private var inputsWereActive = false

    var isOpen: Bool { display != nil }
    var inputsOpen: Bool { inputsCapability != nil }

    // MARK: Display

    /// Shows a card with Yes, No and Close. fresh: restart the display first
    /// (a display can report "started" while the lens shows Meta's home).
    func show(on session: DeviceSession, title: String, body: String, fresh: Bool) async -> Bool {
        guard let target = await attachDisplay(to: session, fresh: fresh) else { return false }
        do {
            let started = Date()
            try await target.send(card(title: title, body: body))
            sendMs = Int(Date().timeIntervalSince(started) * 1000)
            lastCardAt = Date()
            usedInSession = true
            onLog?("display: card sent in \(sendMs ?? 0) ms")
            return true
        } catch {
            lastError = "sending the card failed: \(error)"
            onLog?("display: \(lastError)")
            return false
        }
    }

    private func attachDisplay(to session: DeviceSession, fresh: Bool) async -> Display? {
        needsNewSession = false
        if let current = display, current.state == .started, !fresh { return current }
        if display != nil {
            onLog?("display: restarting it")
            await closeDisplay(clear: false)
        }
        phase = .starting
        var lastFailure = ""
        for attempt in 1...10 {
            if Task.isCancelled { break }
            do {
                let capability = try session.addDisplay()
                displayGen += 1
                let gen = displayGen
                display = capability
                displayTokens.append(capability.statePublisher.listen { [weak self] state in
                    Task { @MainActor in self?.displayStateChanged(state, gen: gen) }
                })
                capability.start()
                _ = await waitUntil(5, step: 0.1) { capability.state == .started }
                if capability.state == .started, displayGen == gen {
                    phase = .on
                    onLog?("display: started (attempt \(attempt))")
                    return capability
                }
                lastFailure = "the display did not start (\(capability.state))"
                await closeDisplay(clear: false)
                phase = .starting
            } catch {
                lastFailure = "\(error)"
                if (error as? DeviceSessionError) == .capabilityAlreadyActive {
                    needsNewSession = true
                    lastError = "the session still holds the old display"
                    phase = .failed(lastError)
                    onLog?("display: \(lastError), a new session is needed")
                    return nil
                }
            }
            onLog?("display: attempt \(attempt) failed: \(lastFailure)")
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        lastError = "could not open the display: \(lastFailure)"
        phase = .failed(lastFailure)
        return nil
    }

    private func displayStateChanged(_ state: DisplayState, gen: Int) {
        guard gen == displayGen else { return }
        onLog?("display: \(state)")
        if state == .stopped, !closingDisplay, display != nil {
            // Stopped by the glasses: let go of it.
            displayGen += 1
            display = nil
            cancel(&displayTokens)
            phase = .off
        }
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
                // Instead of the back gesture, which closes the app on the glasses.
                Button(label: "Close", style: .outline, onClick: { [weak self] in
                    Task { @MainActor in
                        self?.onLog?("display: Close picked on the lens")
                        self?.onClosePressed?()
                    }
                })
            }
        }
    }

    private func chose(_ choice: String) {
        choices.append(choice)
        if choices.count > 30 { choices.removeFirst() }
        onLog?("display: you picked \(choice) on the lens")
        onChoice?(choice)
    }

    /// Clears the lens, stops the display and waits until it has stopped.
    func closeDisplay(clear: Bool = true) async {
        guard let closing = display else {
            if phase != .off && phase != .starting { phase = .off }
            return
        }
        closingDisplay = true
        defer { closingDisplay = false }
        displayGen += 1
        display = nil
        phase = .stopping
        if clear {
            _ = await finishes(within: 2) { _ = try? await closing.clearDisplay() }
        }
        closing.stop()
        _ = await waitUntil(2, step: 0.1) { closing.state == .stopped }
        let tokens = displayTokens
        displayTokens = []
        for token in tokens { await token.cancel() }
        lastCardAt = nil
        phase = .off
    }

    func clearChoices() { choices = [] }

    // MARK: Inputs (frame, Neural Band, buttons)

    /// Starts listening with the given sources; always fresh (an old listener
    /// is removed first). Asking for the Neural Band takes it away from the
    /// card's buttons (Meta's BirdSpotter sample).
    func openInputs(on session: DeviceSession, sources: Set<InputSource>) async -> Bool {
        needsNewSession = false
        await closeInputs(on: session)
        inputsPhase = .starting
        var lastFailure = ""
        for attempt in 1...10 {
            if Task.isCancelled { break }
            do {
                let configuration = InputsConfiguration(sources: sources, consumeBack: true)
                guard let capability = try session.addInputs(configuration: configuration) else {
                    lastError = "these glasses offer no inputs to the toolkit"
                    inputsPhase = .failed(lastError)
                    return false
                }
                inputsGen += 1
                let gen = inputsGen
                inputsCapability = capability
                inputsWereActive = false
                inputsTokens.append(capability.statePublisher.listen { [weak self] state in
                    Task { @MainActor in self?.inputsStateChanged(state, gen: gen) }
                })
                inputsTokens.append(capability.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in
                        guard let self, gen == self.inputsGen else { return }
                        self.onLog?("inputs error: \(error)")
                    }
                })
                inputsReader = Task { [weak self] in
                    for await event in capability.events {
                        guard let self, gen == self.inputsGen else { return }
                        self.received(event)
                    }
                }
                _ = await waitUntil(3, step: 0.1) { capability.state == .active }
                inputsPhase = .on
                onLog?("inputs: listening (attempt \(attempt)), sources \(sources.map { "\($0)" }.sorted().joined(separator: ", "))")
                return true
            } catch {
                lastFailure = "\(error)"
                if (error as? DeviceSessionError) == .capabilityAlreadyActive {
                    needsNewSession = true
                    lastError = "the session still holds the old inputs"
                    inputsPhase = .failed(lastError)
                    return false
                }
                onLog?("inputs: attempt \(attempt) failed: \(lastFailure)")
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
        lastError = "could not attach the inputs: \(lastFailure)"
        inputsPhase = .failed(lastFailure)
        return false
    }

    private func inputsStateChanged(_ state: InputsState, gen: Int) {
        guard gen == inputsGen else { return }
        onLog?("inputs: \(state)")
        switch state {
        case .active:
            inputsWereActive = true
            inputsPhase = .on
        case .inactive where inputsWereActive:
            inputsPhase = .failed("stopped by the glasses")
        default:
            break
        }
    }

    private func received(_ event: InputEvent) {
        if case .drag = event {
            drags += 1
            if drags == 1 || drags % 25 == 0 { onLog?("input: \(drags) drag events so far") }
            return
        }
        let text = Self.describe(event)
        inputs.append(text)
        if inputs.count > 50 { inputs.removeFirst() }
        onLog?("input: \(text)")
    }

    private static func describe(_ event: InputEvent) -> String {
        switch event {
        case .nav(let direction, let source, _): return "swipe \(direction) (\(source))"
        case .select(let source, _): return "select (\(source))"
        case .back(let source, _): return "back (\(source))"
        case .button(let type, let source, _): return "button \(type) (\(source))"
        case .capture(let type, let source, _): return "capture \(type) (\(source))"
        case .drag(let action, _, _, _, _, let source, _): return "drag \(action) (\(source))"
        }
    }

    /// Stops listening: the reader and tokens first, then removeInputs()
    /// (the only way to switch inputs off).
    func closeInputs(on session: DeviceSession) async {
        guard inputsCapability != nil else {
            if inputsPhase != .off && inputsPhase != .starting { inputsPhase = .off }
            return
        }
        inputsGen += 1
        inputsReader?.cancel()
        inputsReader = nil
        inputsCapability = nil
        inputsPhase = .stopping
        let tokens = inputsTokens
        inputsTokens = []
        for token in tokens { await token.cancel() }
        do { try session.removeInputs() } catch { onLog?("inputs: removing them failed: \(error)") }
        inputsPhase = .off
    }

    func clearInputs() {
        inputs = []
        drags = 0
    }

    // MARK: Session gone, app closing

    /// The session ended: everything on it is gone.
    func dropAll() {
        displayGen += 1
        inputsGen += 1
        display = nil
        inputsReader?.cancel()
        inputsReader = nil
        inputsCapability = nil
        cancel(&displayTokens)
        cancel(&inputsTokens)
        lastCardAt = nil
        usedInSession = false
        if phase != .off { phase = .off }
        if inputsPhase != .off { inputsPhase = .off }
    }

    /// The app is closing: no time to wait for answers.
    func shutdownNow(on session: DeviceSession) {
        inputsReader?.cancel()
        if inputsCapability != nil { try? session.removeInputs() }
        display?.stop()
        dropAll()
    }

    private func cancel(_ tokens: inout [any AnyListenerToken]) {
        let old = tokens
        tokens = []
        Task { for token in old { await token.cancel() } }
    }
}
