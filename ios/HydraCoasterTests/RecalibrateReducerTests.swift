import Foundation
import Testing

@testable import HydraCoaster

struct RecalibrateReducerTests {
    @Test func emptyCoasterStep_tareOk_advancesToPlaceWeight() {
        let outcome = RecalibrateReducer.handle(status: CommandStatus(lastCommand: 0x02, result: .ok), for: .emptyCoaster)
        #expect(outcome == .advance(.placeWeight))
    }

    @Test func emptyCoasterStep_tareNoSignal_retriesWithMessage() {
        let outcome = RecalibrateReducer.handle(status: CommandStatus(lastCommand: 0x02, result: .noSignal), for: .emptyCoaster)
        #expect(outcome == .retry(message: "Not settled — wait for a steady reading, then try again."))
    }

    @Test func placeWeightStep_calibrateOk_advancesToDone() {
        let outcome = RecalibrateReducer.handle(status: CommandStatus(lastCommand: 0x03, result: .ok), for: .placeWeight)
        #expect(outcome == .advance(.done))
    }

    @Test func placeWeightStep_loadTooSmall_retriesWithMessage() {
        let outcome = RecalibrateReducer.handle(status: CommandStatus(lastCommand: 0x03, result: .loadTooSmall), for: .placeWeight)
        #expect(outcome == .retry(message: "Load too small — check placement, then try again."))
    }

    @Test func placeWeightStep_badCommand_retriesWithGenericMessage() {
        let outcome = RecalibrateReducer.handle(status: CommandStatus(lastCommand: 0x03, result: .badCommand), for: .placeWeight)
        #expect(outcome == .retry(message: "Unexpected response — try again."))
    }

    @Test func strayStatusFromUnrelatedCommand_isIgnored() {
        // A Buzz Test status shouldn't be mistaken for the tare we're waiting on.
        let outcome = RecalibrateReducer.handle(status: CommandStatus(lastCommand: 0x01, result: .ok), for: .emptyCoaster)
        #expect(outcome == nil)
    }

    @Test func staleTareStatus_duringPlaceWeightStep_isIgnored() {
        let outcome = RecalibrateReducer.handle(status: CommandStatus(lastCommand: 0x02, result: .ok), for: .placeWeight)
        #expect(outcome == nil)
    }

    @Test func doneStep_anyStatus_isIgnored() {
        let outcome = RecalibrateReducer.handle(status: CommandStatus(lastCommand: 0x03, result: .ok), for: .done)
        #expect(outcome == nil)
    }
}
