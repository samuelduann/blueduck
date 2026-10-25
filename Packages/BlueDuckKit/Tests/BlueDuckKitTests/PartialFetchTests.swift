import BlueDuckKit
import XCTest

final class PartialFetchTests: XCTestCase {
    let mb: Int64 = 1024 * 1024

    func testSmallReadExpandsToChunk() {
        let range = PartialFetch.plan(offset: 100 * mb + 10, length: 4096, alignment: 4096, fileSize: 1024 * mb)
        XCTAssertEqual(range.lowerBound, 100 * mb)
        XCTAssertEqual(range.count, Int(PartialFetch.chunkSize))
    }

    func testLargeReadIsKeptAndAligned() {
        let range = PartialFetch.plan(offset: 5000, length: 20 * mb, alignment: 4096, fileSize: 1024 * mb)
        XCTAssertEqual(range.lowerBound, 4096)
        XCTAssertEqual(range.upperBound % 4096, 0)
        XCTAssertGreaterThanOrEqual(range.upperBound, 5000 + 20 * mb)
    }

    func testNearEndExtendsToEOF() {
        let size = 100 * mb + 123
        let range = PartialFetch.plan(offset: 88 * mb, length: 4096, alignment: 4096, fileSize: size)
        XCTAssertEqual(range, 88 * mb..<size)
    }

    func testSmallFileIsFetchedWhole() {
        XCTAssertEqual(PartialFetch.plan(offset: 0, length: 4096, alignment: 4096, fileSize: 3 * mb), 0..<3 * mb)
        XCTAssertEqual(PartialFetch.plan(offset: 0, length: 0, alignment: 4096, fileSize: 0), 0..<0)
    }

    func testAlignmentLargerThanChunk() {
        let align = 16 * mb
        let range = PartialFetch.plan(offset: 40 * mb, length: 1, alignment: align, fileSize: 1024 * mb)
        XCTAssertEqual(range, 32 * mb..<48 * mb)
    }
}
