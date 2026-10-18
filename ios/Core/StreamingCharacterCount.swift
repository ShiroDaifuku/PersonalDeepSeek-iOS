import Foundation

/// Exact extended-grapheme count across stream boundaries. Only the final cluster can
/// merge with appended text. Never recount the full reasoning/content accumulated so far.
struct StreamingCharacterCount: Sendable {
    private(set) var count = 0
    private(set) var scannedUTF8Bytes = 0
    private var tail = ""

    mutating func append(_ fragment: String) {
        guard !fragment.isEmpty else { return }
        let boundary = tail + fragment
        let boundaryCount = boundary.count
        scannedUTF8Bytes += boundary.utf8.count
        count += boundaryCount - (tail.isEmpty ? 0 : 1)
        tail = boundary.last.map(String.init) ?? ""
    }
}
