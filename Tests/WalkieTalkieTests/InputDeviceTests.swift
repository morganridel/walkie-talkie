import XCTest
@testable import WalkieTalkie

final class InputDeviceTests: XCTestCase {
    private let mac = InputDevice.Device(id: 1, name: "MacBook Air Microphone", manufacturer: "Apple", uid: "builtin")
    private let usb = InputDevice.Device(id: 2, name: "USBAudio1.0", manufacturer: "Jieli Technology", uid: "usb:mic:123")

    func testAutomaticUsesDefaultUSBInsteadOfKnownBuiltIn() {
        let result = InputDevice.resolve(devices: [mac, usb], defaultDevice: usb, choice: "auto")
        XCTAssertEqual(result.device?.uid, usb.uid)
        XCTAssertNil(result.known)
        XCTAssertEqual(InputDevice.resolve(devices: [usb, mac], defaultDevice: mac, choice: "auto").device?.uid, mac.uid)
    }

    func testExplicitUIDSurvivesNumericIDChangeAndDuplicateNames() {
        let reconnected = InputDevice.Device(id: 99, name: usb.name, manufacturer: usb.manufacturer, uid: usb.uid)
        let other = InputDevice.Device(id: 3, name: usb.name, manufacturer: usb.manufacturer, uid: "different-unit")
        let choice = InputDevice.selectionID(for: usb)
        let result = InputDevice.resolve(devices: [mac, other, reconnected], defaultDevice: mac, choice: choice)
        XCTAssertEqual(result.device?.id, 99)
    }

    func testUnplugFallsBackAndReplugRestoresExplicitChoice() {
        let choice = InputDevice.selectionID(for: usb)
        XCTAssertEqual(InputDevice.resolve(devices: [mac], defaultDevice: mac, choice: choice).device?.uid, mac.uid)
        XCTAssertEqual(InputDevice.resolve(devices: [mac, usb], defaultDevice: mac, choice: choice).device?.uid, usb.uid)
        XCTAssertNil(InputDevice.resolve(devices: [], defaultDevice: nil, choice: choice).device)
    }

    func testLegacyExplicitMacChoiceIsPreserved() {
        XCTAssertEqual(InputDevice.resolve(devices: [mac, usb], defaultDevice: usb, choice: "mac").device?.uid, mac.uid)
    }

    func testPickerIncludesUnfamiliarUSBAndPreferencePreservesDisconnectedUID() {
        let choices = InputDevice.choices(devices: [mac, usb])
        let choice = InputDevice.selectionID(for: usb)
        XCTAssertTrue(choices.contains { $0.id == choice && $0.label.contains("USBAudio1.0") })
        XCTAssertEqual(MicChoice.normalized(choice, known: []), choice)
        XCTAssertEqual(MicChoice.deviceUID(choice), usb.uid)
        for invalid in ["uid:", "uid:!invalid!", "unknown", "uid:/w=="] {
            XCTAssertEqual(MicChoice.normalized(invalid, known: ["mac"]), "auto")
        }
    }
}
