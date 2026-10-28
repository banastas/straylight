// Copied from flatline's FlatlineKit (PRD §13: copy for now, extract a shared package later).

/// Fixed-capacity history that starts full of `fill`, so traces begin as a flat line.
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element]
    private var head = 0

    public init(capacity: Int, fill: Element) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [Element](repeating: fill, count: capacity)
    }

    public mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
    }

    /// Oldest first.
    public var elements: [Element] {
        Array(storage[head...] + storage[..<head])
    }

    /// The newest `count` elements, oldest first.
    public func suffix(_ count: Int) -> [Element] {
        let count = min(count, capacity)
        var result: [Element] = []
        result.reserveCapacity(count)
        for offset in (capacity - count)..<capacity {
            result.append(storage[(head + offset) % capacity])
        }
        return result
    }

    public var last: Element {
        storage[(head + capacity - 1) % capacity]
    }
}
