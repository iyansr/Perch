import CoreGraphics
import Testing
@testable import Perch

struct IslandPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func staysCentredWhenExtrasAreClear() {
        #expect(NotchGeometry.islandCenterX(screenFrame: screen, extrasEdge: nil) == 960)
        #expect(NotchGeometry.islandCenterX(screenFrame: screen, extrasEdge: 1400) == 960)
    }

    @Test func movesLeftOfExtrasThatReachUnderIt() {
        let center = NotchGeometry.islandCenterX(screenFrame: screen, extrasEdge: 947)
        let islandRight = center + NotchGeometry.islandClearance / 2
        #expect(islandRight <= 947 - NotchGeometry.extrasGap)
        #expect(islandRight >= 947 - NotchGeometry.extrasGap - 1) // snug, not further than needed
    }

    @Test func neverPushesTheWindowOffScreen() {
        let center = NotchGeometry.islandCenterX(screenFrame: screen, extrasEdge: 100)
        #expect(center == NotchGeometry.windowSize.width / 2)
    }
}
