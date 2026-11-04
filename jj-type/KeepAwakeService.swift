//
//  KeepAwakeService.swift
//  jj-type
//
//  Menu-driven "caffeine" toggle: runs /usr/bin/caffeinate (-d -i -s) while a
//  session is active, with an optional timed expiry. Indefinite mode has NO
//  -t cap on purpose (the product decision is "until manually turned off");
//  quit-time cleanup in shutdown() is the guaranteed kill path.
//

import AppKit

/// Chinese-message wrapper for keep-awake failures.
struct KeepAwakeError: LocalizedError {
    let reason: String

    var errorDescription: String? { "无法开启防休眠：\(reason)" }
}

final class KeepAwakeService {
    /// Fires on every state change (start / stop / external process death) and
    /// once per minute while a timed session runs (menu countdown). The owner
    /// rebuilds the status menu section and swaps the status icon.
    var onChanged: (() -> Void)?

    private(set) var isActive = false
    /// Length of the current session; nil while inactive OR running indefinitely.
    private(set) var sessionDuration: TimeInterval?
    /// Expiry of the current timed session; nil while inactive OR indefinite.
    private(set) var deadline: Date?

    private var process: Process?
    private var expiryTimer: Timer?
    private var countdownTimer: Timer?
    /// True while WE terminate the process — the exit handler then stays silent
    /// instead of reporting an "external death" and double-notifying the UI.
    private var stopping = false

    /// Starts caffeinate. `duration == nil` runs until disable(); a finite
    /// duration auto-stops at the deadline. Re-enabling replaces the session.
    func enable(for duration: TimeInterval?) throws {
        stopSession()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -d keep the display awake, -i prevent system idle sleep,
        // -s prevent system sleep on AC power.
        process.arguments = ["-d", "-i", "-s"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Fires on an arbitrary background queue — hop to the main actor
        // explicitly. (The Carbon assumeIsolated pattern does NOT apply here:
        // this callback is not guaranteed to arrive on the main thread.)
        // The exited process is passed through so a STALE handler (a session
        // replaced before its exit landed) can be detected and ignored.
        process.terminationHandler = { [weak self] exited in
            Task { @MainActor in self?.handleProcessExit(of: exited) }
        }

        do {
            try process.run()
        } catch {
            // The previous session was already stopped silently above — sync
            // the UI to the off state before surfacing the failure, so no
            // stale "已开启" menu / icon survives a failed start.
            onChanged?()
            throw KeepAwakeError(reason: "caffeinate 不可用（\(error.localizedDescription)）")
        }

        self.process = process
        isActive = true
        sessionDuration = duration
        if let duration {
            deadline = Date().addingTimeInterval(duration)
            expiryTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
                [weak self] _ in self?.disable()
            }
            // Once-a-minute UI tick so the menu title can count down.
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
                [weak self] _ in self?.onChanged?()
            }
        }
        onChanged?()
    }

    /// Stops the active session (idempotent).
    func disable() {
        guard isActive else { return }
        stopSession()
        onChanged?()
    }

    /// Quit-time cleanup: SIGTERM plus a short run-loop pump so no caffeinate
    /// child outlives the app (macOS does NOT kill child processes with the
    /// parent). Called from applicationWillTerminate.
    func shutdown() {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        stopping = true
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, process.isRunning {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        self.process = nil
        stopping = false
    }

    /// Whole minutes left in a timed session (rounded up, floor 1), for the
    /// menu title. nil while inactive or indefinite.
    var remainingMinutes: Int? {
        guard let deadline else { return nil }
        return max(1, Int(ceil(deadline.timeIntervalSinceNow / 60)))
    }

    // MARK: - Private

    /// Clears timers + state and terminates the child, WITHOUT notifying.
    /// The process ref is dropped immediately — the (possibly late) exit
    /// handler identifies itself and stays harmless via its identity check.
    private func stopSession() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        deadline = nil
        sessionDuration = nil
        isActive = false
        if let process {
            if process.isRunning {
                stopping = true
                process.terminate() // SIGTERM; caffeinate exits promptly.
            }
            self.process = nil
        }
    }

    /// terminationHandler's main-actor landing point. A handler whose process
    /// is no longer the current one (session already replaced) is ignored;
    /// otherwise an unexpected death (e.g. caffeinate killed externally)
    /// syncs the state and UI back to off. User-initiated stops stay silent.
    private func handleProcessExit(of exited: Process) {
        let wasStopping = stopping
        stopping = false
        guard exited === process else { return }
        process = nil
        guard !wasStopping, isActive else { return }
        isActive = false
        expiryTimer?.invalidate()
        expiryTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        deadline = nil
        sessionDuration = nil
        onChanged?()
    }
}
