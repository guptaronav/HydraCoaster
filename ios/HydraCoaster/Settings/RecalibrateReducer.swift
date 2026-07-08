import Foundation

/// The three steps of the guided recalibration sheet.
enum RecalibrateStep: Equatable {
    case emptyCoaster
    case placeWeight
    case done
}

enum RecalibrateOutcome: Equatable {
    case advance(RecalibrateStep)
    case retry(message: String)
}

/// Matches a D008 command-status notification to the command the current
/// step is actually waiting on — a stray status from an unrelated command
/// (e.g. a Buzz Test fired from Settings while a sheet is up) must not be
/// mistaken for the tare/calibrate response — then turns the result into a
/// step transition or a retry message. Pure so it's testable without
/// CoreBluetooth in the loop.
enum RecalibrateReducer {
    private static let tareCommand: UInt8 = 0x02
    private static let calibrateCommand: UInt8 = 0x03

    static func handle(status: CommandStatus, for step: RecalibrateStep) -> RecalibrateOutcome? {
        let expectedCommand: UInt8
        let nextStep: RecalibrateStep
        switch step {
        case .emptyCoaster:
            expectedCommand = tareCommand
            nextStep = .placeWeight
        case .placeWeight:
            expectedCommand = calibrateCommand
            nextStep = .done
        case .done:
            return nil
        }
        guard status.lastCommand == expectedCommand else { return nil }
        return status.result == .ok ? .advance(nextStep) : .retry(message: message(for: status.result))
    }

    private static func message(for result: CommandResult) -> String {
        switch result {
        case .ok:
            ""
        case .noSignal:
            "Not settled — wait for a steady reading, then try again."
        case .loadTooSmall:
            "Load too small — check placement, then try again."
        case .badCommand, .unknown:
            "Unexpected response — try again."
        }
    }
}
