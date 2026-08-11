import CoreGraphics
import XCTest

@testable import Pomo

final class PomoViewMotionTests: XCTestCase {
    func test_hoverHitRegion_matchesRoundedGlassInsteadOfTheLargerPillBounds() {
        for size in PomoSize.allCases {
            for digits in 2...3 {
                let layout = PillLayout(sizeClass: size, minuteDigits: digits)
                let region = HoverHitRegion.resolve(layout: layout)

                XCTAssertEqual(region.size, CGSize(width: layout.glassW, height: layout.glassH))
                XCTAssertEqual(region.cornerRadius,
                               layout.glassH * Tokens.Decor.cornerFactor,
                               accuracy: 1e-12)
                XCTAssertLessThan(region.size.width, layout.pillW)
                XCTAssertLessThan(region.size.height, layout.pillH)
            }
        }
    }

    func test_hoverScaleFactors_expandsOnlyGlassAndKeepsContentFixed() {
        let idle = HoverScaleFactors.resolve(isHovering: false, hoverScale: 1.03)
        let hovering = HoverScaleFactors.resolve(isHovering: true, hoverScale: 1.03)

        XCTAssertEqual(idle, HoverScaleFactors(glass: 1, content: 1))
        XCTAssertEqual(hovering, HoverScaleFactors(glass: 1.03, content: 1))
    }

    func test_durationEditorLayout_withZeroOrOneCharacter_reservesTwoMinuteSlots() {
        XCTAssertEqual(
            DurationEditorLayout.resolve(draft: "").minuteTemplate,
            "00"
        )
        XCTAssertEqual(
            DurationEditorLayout.resolve(draft: "5").minuteTemplate,
            "00"
        )
    }

    func test_durationEditorLayout_withTwoOrMoreCharacters_capsAtThreeMinuteSlots() {
        XCTAssertEqual(DurationEditorLayout.resolve(draft: "45").minuteTemplate, "00")
        XCTAssertEqual(DurationEditorLayout.resolve(draft: "180").minuteTemplate, "000")
        XCTAssertEqual(DurationEditorLayout.resolve(draft: "9999").minuteTemplate, "000")
    }

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
