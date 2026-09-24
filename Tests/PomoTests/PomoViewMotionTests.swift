import CoreGraphics
import SwiftUI
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

    func test_updateSpin_staysStillUntilTheUpdateStarts() {
        let now = Date(timeIntervalSinceReferenceDate: 10)
        XCTAssertEqual(UpdateSpin.degrees(now: now, started: nil, active: false), 0)
        XCTAssertEqual(UpdateSpin.degrees(now: now, started: now, active: false), 0)
    }

    func test_updateSpin_turnsOncePerPeriodWhileInstalling() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let quarter = Date(timeIntervalSinceReferenceDate: UpdateSpin.period / 4)
        let lap = Date(timeIntervalSinceReferenceDate: UpdateSpin.period)
        let extra = Date(timeIntervalSinceReferenceDate: UpdateSpin.period * 2.5)

        XCTAssertEqual(UpdateSpin.degrees(now: quarter, started: start, active: true), 90, accuracy: 1e-9)
        XCTAssertEqual(UpdateSpin.degrees(now: lap, started: start, active: true), 0, accuracy: 1e-9)
        XCTAssertEqual(UpdateSpin.degrees(now: extra, started: start, active: true), 180, accuracy: 1e-9)
    }

    func test_taskSlotOffsets_withReduceMotion_usesNoVerticalMovement() {
        let idle = TaskSlotOffsets.resolve(isEditing: false, distance: 24, reduceMotion: true)
        let editing = TaskSlotOffsets.resolve(isEditing: true, distance: 24, reduceMotion: true)

        XCTAssertEqual(idle, TaskSlotOffsets(display: 0, editor: 0))
        XCTAssertEqual(editing, TaskSlotOffsets(display: 0, editor: 0))
    }

    func test_glassHighlight_restsOnTheTopEdgeWhenThePointerIsCentered() {
        let direction = GlassHighlightDirection.resolve(offsetX: 0, offsetY: 0)

        XCTAssertEqual(direction.maskStart, UnitPoint(x: 0.5, y: 0))
        XCTAssertEqual(direction.maskEnd, UnitPoint(x: 0.5, y: 1))
    }

    func test_glassHighlight_facesTheSideThePointerIsOn() {
        let right = GlassHighlightDirection.resolve(offsetX: 80, offsetY: 0)
        let left = GlassHighlightDirection.resolve(offsetX: -4, offsetY: 0)
        let below = GlassHighlightDirection.resolve(offsetX: 0, offsetY: 30)
        let above = GlassHighlightDirection.resolve(offsetX: 0, offsetY: -9)

        XCTAssertEqual(right.maskStart, UnitPoint(x: 1, y: 0.5))
        XCTAssertEqual(right.maskEnd, UnitPoint(x: 0, y: 0.5))
        XCTAssertEqual(left.maskStart, UnitPoint(x: 0, y: 0.5))
        XCTAssertEqual(below.maskStart, UnitPoint(x: 0.5, y: 1))
        XCTAssertEqual(above.maskStart, UnitPoint(x: 0.5, y: 0))
    }

    func test_glassHighlight_readsAppKitPointsWithYGrowingUpward() {
        let above = GlassHighlightDirection.resolve(localX: 10, localY: 40, midX: 10, midY: 20)
        let left = GlassHighlightDirection.resolve(localX: 2, localY: 20, midX: 10, midY: 20)

        XCTAssertEqual(above.maskStart, UnitPoint(x: 0.5, y: 0))
        XCTAssertEqual(left.maskStart, UnitPoint(x: 0, y: 0.5))
    }

    func test_glassHighlight_keepsTheBrightSpotCenteredOnTheFacingEdge() {
        let right = GlassHighlightDirection.resolve(offsetX: 10, offsetY: 0)
        let near = GlassHighlightDirection.resolve(offsetX: 2, offsetY: -2)
        let far = GlassHighlightDirection.resolve(offsetX: 50, offsetY: -50)

        XCTAssertEqual(right.strokeStart.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(right.strokeEnd.x, 0.5, accuracy: 1e-9)
        XCTAssertNotEqual(right.strokeStart.y, right.strokeEnd.y)
        XCTAssertEqual(near, far)
    }

    func test_glassHighlight_followsADiagonalPointer() {
        let direction = GlassHighlightDirection.resolve(offsetX: 3, offsetY: 3)
        let edge = 0.5 + (sqrt(2) / 4)

        XCTAssertEqual(direction.maskStart.x, edge, accuracy: 1e-9)
        XCTAssertEqual(direction.maskStart.y, edge, accuracy: 1e-9)
    }
}
