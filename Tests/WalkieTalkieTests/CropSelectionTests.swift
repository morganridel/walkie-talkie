import XCTest
@testable import WalkieMacKit

final class CropSelectionTests: XCTestCase {
    func testDragUsesNormalizedScreenRectangle() {
        var geometry = CropSelectionGeometry(anchor: CGPoint(x: 10, y: 20))
        geometry.update(to: CGPoint(x: 40, y: 70))

        XCTAssertEqual(geometry.rect(minimum: 6), CGRect(x: 10, y: 20, width: 30, height: 50))
    }

    func testOptionDrawsFromTheCenter() {
        var geometry = CropSelectionGeometry(anchor: CGPoint(x: 100, y: 100))
        geometry.update(to: CGPoint(x: 125, y: 140), option: true)

        XCTAssertTrue(geometry.isCentered)
        XCTAssertEqual(geometry.rect(minimum: 6), CGRect(x: 75, y: 60, width: 50, height: 80))
    }

    func testCommandMovesTheBoxThenResumesResizing() {
        var geometry = CropSelectionGeometry(anchor: CGPoint(x: 10, y: 10))
        geometry.update(to: CGPoint(x: 40, y: 40))
        geometry.update(to: CGPoint(x: 50, y: 55), command: true)
        XCTAssertTrue(geometry.isMoving)
        XCTAssertEqual(geometry.rect(), CGRect(x: 20, y: 25, width: 30, height: 30))

        geometry.update(to: CGPoint(x: 60, y: 60)) // modifier release retains the moved box
        XCTAssertFalse(geometry.isMoving)
        XCTAssertEqual(geometry.rect(), CGRect(x: 20, y: 25, width: 30, height: 30))
        geometry.update(to: CGPoint(x: 65, y: 75))
        XCTAssertEqual(geometry.rect(), CGRect(x: 20, y: 25, width: 45, height: 50))
    }

    func testDisplayClippingAndMinimumSizeAreAppliedAfterClipping() {
        var geometry = CropSelectionGeometry(anchor: CGPoint(x: 90, y: 90))
        geometry.update(to: CGPoint(x: 110, y: 110))

        XCTAssertEqual(geometry.rect(minimum: 6, within: CGRect(x: 0, y: 0, width: 100, height: 100)),
                       CGRect(x: 90, y: 90, width: 10, height: 10))
        XCTAssertNil(geometry.rect(minimum: 11, within: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }

    func testCancellationIsTerminalAndCanOnlyWinOnce() {
        var lifecycle = CropSelectionLifecycle()

        XCTAssertTrue(lifecycle.cancel())
        XCTAssertEqual(lifecycle.end, .cancelled)
        XCTAssertFalse(lifecycle.cancel())
        XCTAssertFalse(lifecycle.complete())
    }
}
