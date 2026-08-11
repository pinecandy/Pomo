import CoreGraphics
import XCTest

@testable import Pomo

final class PomoViewMotionTests: XCTestCase {
    func test_taskSlotOffsets_whenIdle_keepsTitleAndStagesEditorBelow() {
        let offsets = TaskSlotOffsets.resolve(isEditing: false, distance: 24, reduceMotion: false)

        XCTAssertEqual(offsets, TaskSlotOffsets(display: 0, editor: 24))
    }

    func test_taskSlotOffsets_whenEditing_movesTitleUpAndPlacesEditorAtRest() {
        let offsets = TaskSlotOffsets.resolve(isEditing: true, distance: 24, reduceMotion: false)

        XCTAssertEqual(offsets, TaskSlotOffsets(display: -24, editor: 0))
    }

    func test_taskSlotOffsets_withReduceMotion_usesNoVerticalMovement() {
        let idle = TaskSlotOffsets.resolve(isEditing: false, distance: 24, reduceMotion: true)
        let editing = TaskSlotOffsets.resolve(isEditing: true, distance: 24, reduceMotion: true)

        XCTAssertEqual(idle, TaskSlotOffsets(display: 0, editor: 0))
        XCTAssertEqual(editing, TaskSlotOffsets(display: 0, editor: 0))
    }
}
