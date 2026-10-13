import Foundation
import Testing
@testable import AetherEngine

struct PanelReadoutLineTests {

    @Test("AE#459: the readout prints both headrooms, because the two panels in this thread disagree")
    func printsBothHeadrooms() {
        let line = DisplayCriteriaController.panelReadoutLine(
            phase: "before apply", currentEDR: 1.2, potentialEDR: 1.0,
            switching: false, matching: true, hdrEligible: true, proven: true,
            headroomLimit: "inactive")
        #expect(line == "[DisplayCriteria] panel readout before apply: currentEDR=1.20 "
                + "potentialEDR=1.00 headroomLimit=inactive switching=no matching=on hdrEligible=yes "
                + "provenHDR=yes")
    }

    @Test("AE#459: the silent panel's shape, which is what a reporter is asked to grep for")
    func silentPanelShape() {
        let line = DisplayCriteriaController.panelReadoutLine(
            phase: "before reset", currentEDR: 1.0, potentialEDR: 1.0,
            switching: false, matching: false, hdrEligible: false, proven: false,
            headroomLimit: "active")
        #expect(line == "[DisplayCriteria] panel readout before reset: currentEDR=1.00 "
                + "potentialEDR=1.00 headroomLimit=active switching=no matching=off hdrEligible=no "
                + "provenHDR=no")
    }

    @Test("AE#459: two decimals, so a headroom that moves a little still shows it")
    func headroomKeepsTwoDecimals() {
        let line = DisplayCriteriaController.panelReadoutLine(
            phase: "before apply", currentEDR: 1.0499, potentialEDR: 16.0,
            switching: true, matching: true, hdrEligible: true, proven: false,
            headroomLimit: "unspecified")
        #expect(line.contains("currentEDR=1.05"))
        #expect(line.contains("potentialEDR=16.00"))
        #expect(line.contains("switching=yes"))
        #expect(line.contains("headroomLimit=unspecified"))
    }
}
