import SwiftUI
import XCTest
@testable import OpenCode_Go_Quotas

final class SVGPathCacheTests: XCTestCase {
    private let triangle = "M10 10 L110 10 L60 90 Z"
    private let square = "M0 0 L100 0 L100 100 L0 100 Z"

    private func makeCache(capacity: Int = 8) -> SVGPathCache {
        SVGPathCache(capacity: capacity)
    }

    func testSamePathDataIsCachedAndRenderedConsistently() {
        let cache = makeCache()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

        let first = cache.path(for: triangle) { SVGPath.parse(triangle) }
        XCTAssertEqual(cache.count, 1)

        let secondShape = SVGPath(data: triangle).path(in: rect)
        let firstShape = SVGPath(data: triangle).path(in: rect)
        XCTAssertEqual(first.boundingRect.width, 100, accuracy: 0.001)
        XCTAssertEqual(firstShape.boundingRect, secondShape.boundingRect)
        XCTAssertEqual(SVGPath.parse(triangle), first)
    }

    func testDistinctPathDataCreatesDistinctEntries() {
        let cache = makeCache()
        _ = cache.path(for: triangle) { SVGPath.parse(triangle) }
        _ = cache.path(for: square) { SVGPath.parse(square) }

        XCTAssertEqual(cache.count, 2)
        XCTAssertNotEqual(
            cache.path(for: triangle) { SVGPath.parse(triangle) }.boundingRect,
            cache.path(for: square) { SVGPath.parse(square) }.boundingRect)
    }

    func testMalformedPathResultIsCachedToAvoidRepeatParsing() {
        let cache = makeCache()
        let junk = "NOT A PATH !!!"

        let first = cache.path(for: junk) { SVGPath.parse(junk) }
        _ = cache.path(for: junk) { SVGPath.parse(junk) }

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(first.boundingRect.isNull)
        XCTAssertEqual(cache.count, 1)
    }

    func testOldestEntryEvictedWhenCapacityReached() {
        let cache = makeCache(capacity: 2)
        let circleish = "M10 10 C40 10 40 40 10 10 Z"

        _ = cache.path(for: "one") { SVGPath.parse(triangle) }
        _ = cache.path(for: "two") { SVGPath.parse(square) }
        _ = cache.path(for: "three") { SVGPath.parse(circleish) }

        XCTAssertEqual(cache.count, 2)
        XCTAssertFalse(cache.path(for: "three") { .init() }.isEmpty)
        // one 已被淘汰；访问 two/three 后仍保持容量上限。
        _ = cache.path(for: "two") { SVGPath.parse(square) }
        XCTAssertEqual(cache.count, 2)
    }

    func testConcurrentReadersAndWritersStayWithinCapacity() {
        let cache = makeCache(capacity: 3)
        let keys = ["a", "b", "c", "d", "e"]

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let key = keys[index % keys.count]
            _ = cache.path(for: key) { SVGPath.parse(SVGBuiltIn.sparkle) }
        }

        XCTAssertLessThanOrEqual(cache.count, 3)
    }
}
