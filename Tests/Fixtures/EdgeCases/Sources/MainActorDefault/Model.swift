final class Model {
    var count = 0
    func increment() { count += 1 }
    nonisolated func pureValue() -> Int { 42 }
    var label: String { "count: \(count)" }
}

#if canImport(SwiftUI)
import SwiftUI

struct Label: View {
    var title = "title"
    var body: some View { caption }
    var caption: some View { Text(title).font(.caption) }
    func detail(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return Text(trimmed)
    }
}
#endif
