import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

public enum Mode { case a, b }

public struct Edge: Sendable {
    public var value: Int
    public init(value: Int) { self.value = value }

    public func ifExpression(_ flag: Bool) -> Int {
        if flag { 1 } else { 2 }
    }

    public func switchExpression(_ mode: Mode) -> String {
        switch mode {
        case .a: "a"
        case .b: "b"
        }
    }

    public func switchStatement(_ mode: Mode) -> Int {
        switch mode {
        case .a: return 1
        case .b: return 2
        }
    }

    public func guardBody(_ x: Int?) -> Int {
        guard let x else { return -1 }
        return x
    }

    public func crash() -> Int {
        fatalError("not implemented")
    }

    public mutating func bump() { value += 1 }

    public static func make() -> Edge? { Edge(value: 0) }

    public func asyncValue() async -> Double { 1.5 }

    public func throwing() throws -> [String: Int] { ["a": 1] }

    public func typedThrowing() throws(CancellationError) -> Set<Int> { [1] }

    public func generic<T>(_ value: T) -> [T] { [value] }

    public func tryExpression() throws -> Int { try Int(throwing()["a"] ?? 0) }

    public func oneLiner() -> Bool { value > 0 }; public func second() -> Bool { value < 0 }

    public var both: Int {
        get { value * 2 }
        set { value = newValue / 2 }
    }

    public var withReturn: UInt8 {
        return 3
    }

    public var data: Data { Data([1, 2]) }

    @inlinable public func inlined() -> Int { 1 }

    public func voidWithReturnType() -> Void { _ = value }

    public func optionalChain() -> String? { value > 0 ? "x" : nil }

    public func closureBody() -> [Int] {
        [1, 2].map { x in
            return x * 2
        }
    }

    #if DEBUG
    public func debugOnly() -> Int { 7 }
    #endif
}

public protocol Describable { func describe() -> String }

extension Describable {
    public func describe() -> String { "default" }
}

public actor Counter {
    var count = 0
    public init() {}
    public func next() -> Int { count += 1; return count }
}

@MainActor public final class ViewModel {
    public init() {}
    public var title: String { "title" }
    public func load() async throws {}
}

public func freeFunction(_ x: Int) -> Int { x * x } // trailing comment

#if canImport(SwiftUI)
public struct Greeting: View {
    public init() {}
    public var body: some View {
        VStack {
            Text("Hello")
        }
    }

    @ViewBuilder public func row(_ flag: Bool) -> some View {
        if flag { Text("on") } else { Text("off") }
    }

    public func plain() -> some View { Text("plain") }
}
#endif
