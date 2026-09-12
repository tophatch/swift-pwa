import Foundation
@testable import SwiftPWACLISupport
import Testing

/// The path arithmetic behind `drive drag`.
///
/// The moves between the endpoints are the whole reason this verb exists — a
/// press and a release with nothing in between drives no momentum, inertia or
/// rubber-banding, which is most of what a drag gesture is for. So the shape of
/// the interpolated path is the thing worth asserting; delivering it needs a
/// running app and is covered by driving one.
@Suite("drive drag path")
struct DriveDragPathTests {
    private func point(_ x: Double, _ y: Double) -> DragPoint {
        DragPoint(argument: "\(x),\(y)")!
    }

    @Test("a point parses as x,y and nothing else")
    func parsesCoordinates() {
        #expect(DragPoint(argument: "10,20")?.x == 10)
        #expect(DragPoint(argument: " 10 , 20 ")?.y == 20)
        #expect(DragPoint(argument: "-4.5,0")?.x == -4.5)
        // A bare number is the plausible typo, and taking it as (n, 0) would
        // drag somewhere the caller never asked for.
        #expect(DragPoint(argument: "10") == nil)
        #expect(DragPoint(argument: "10,20,30") == nil)
        #expect(DragPoint(argument: "a,b") == nil)
        #expect(DragPoint(argument: "") == nil)
    }

    @Test("the path keeps its endpoints and passes through every corner")
    func keepsCorners() {
        let path = [point(0, 0), point(100, 0), point(100, 100)]
        let moves = DriveDrag.interpolate(path, steps: 20)
        #expect(moves.first?.x == 0)
        #expect(moves.first?.y == 0)
        #expect(moves.last?.x == 100)
        #expect(moves.last?.y == 100)
        // The corner itself has to be a delivered position: a page that tracks
        // direction would otherwise see one diagonal instead of two legs.
        #expect(moves.contains { $0.x == 100 && $0.y == 0 })
    }

    @Test("steps are spread by distance, not one share per segment")
    func spreadsByDistance() {
        // A long leg and a short one. Splitting per segment would crawl along
        // the short leg and jump along the long one — two different gestures to
        // a page reading velocity.
        let moves = DriveDrag.interpolate([point(0, 0), point(300, 0), point(300, 100)], steps: 40)
        let firstLeg = moves.count(where: { $0.y == 0 && $0.x > 0 })
        let secondLeg = moves.count(where: { $0.x == 300 && $0.y > 0 })
        #expect(firstLeg > secondLeg)
        // 3:1 in length, so roughly 3:1 in moves rather than 1:1.
        #expect(Double(firstLeg) / Double(secondLeg) > 2)
    }

    @Test("a zero-length segment still gets a move rather than being dropped")
    func keepsRepeatedPoint() {
        // Pausing at a corner mid-drag is a real gesture, and a segment that
        // covers no distance would otherwise take a zero share of the steps and
        // vanish. It gets one, and the rest go to the leg that has length.
        let moves = DriveDrag.interpolate([point(10, 10), point(10, 10), point(110, 10)], steps: 10)
        #expect(moves.count(where: { $0.x == 10 && $0.y == 10 }) == 2)
        #expect(moves.last?.x == 110)

        // A path that goes nowhere at all has no distance to spread by, so the
        // steps divide evenly instead of collapsing the gesture to two events.
        let held = DriveDrag.interpolate([point(10, 10), point(10, 10)], steps: 10)
        #expect(held.count > 2)
        #expect(held.allSatisfy { $0.x == 10 && $0.y == 10 })
    }

    @Test("a single point is left alone rather than divided by zero")
    func toleratesDegeneratePath() {
        #expect(DriveDrag.interpolate([point(5, 5)], steps: 10).count == 1)
        #expect(DriveDrag.interpolate([], steps: 10).isEmpty)
    }

    @Test("the default step count is bounded at both ends")
    func boundsDefaultSteps() {
        // The floor stops --duration 0 collapsing to a press and a release with
        // no path at all; the ceiling stops a long drag spending its whole
        // budget on round trips, each a synchronous request to the app.
        #expect(DriveDrag.defaultSteps(forMilliseconds: 0) == 8)
        #expect(DriveDrag.defaultSteps(forMilliseconds: 10000) == 60)
        #expect(DriveDrag.defaultSteps(forMilliseconds: 250) == 31)
    }
}
