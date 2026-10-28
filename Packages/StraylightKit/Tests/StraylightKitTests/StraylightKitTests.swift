import Foundation
import Testing
@testable import StraylightKit

@Suite struct FormatTests {
    @Test func percentClamps() {
        #expect(Format.percent(0.234) == "23%")
        #expect(Format.percent(1.7) == "100%")
        #expect(Format.percent(-1) == "0%")
    }

    @Test func duration() {
        #expect(Format.duration(59) == "0m")
        #expect(Format.duration(4 * 3600 + 12 * 60) == "4h 12m")
        #expect(Format.duration(3 * 86400 + 4 * 3600 + 5) == "3d 4h")
    }

    @Test func leftPadded() {
        #expect("23".leftPadded(to: 4) == "  23")
        #expect("1234".leftPadded(to: 3) == "1234")
    }
}

@Suite struct RingBufferTests {
    @Test func startsFlatAndKeepsNewest() {
        var buffer = RingBuffer(capacity: 3, fill: 0)
        #expect(buffer.elements == [0, 0, 0])
        for value in 1...4 { buffer.append(value) }
        #expect(buffer.elements == [2, 3, 4])
        #expect(buffer.last == 4)
        #expect(buffer.suffix(2) == [3, 4])
    }
}
