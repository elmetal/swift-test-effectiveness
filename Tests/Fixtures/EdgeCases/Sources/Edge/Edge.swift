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

    #if STE_NEVER_DEFINED
    public func neverCompiled() -> Int { 8 }
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

    // `some View` outside a result builder: the original body moves into a local function.
    public var header: some View {
        HStack { Text("header") }
    }

    public var explicitGetter: some View {
        get { return Text(verbatim: "getter") }
    }

    public func severalReturns(_ flag: Bool) -> some View {
        let prefix = flag ? "on" : "off"
        guard flag else { return Text(verbatim: prefix).bold() }
        return Text(verbatim: prefix + "!").bold()
    }

    public func ifExpression(_ flag: Bool) -> some View {
        if flag { Text("on") } else { Text("off") }
    }

    public func generic<Content: View>(_ content: Content) -> some View { content.padding() }

    public func closureParameter(@ViewBuilder content: () -> some View) -> some View {
        VStack { content() }
    }

    public func closureWithReturn(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { item in
            return Text(item)
        }
    }

    public func qualified() -> some SwiftUI.View { Text("qualified") }

    public func asyncThrowing() async throws -> some View {
        try await Task.sleep(nanoseconds: 1)
        return Text("loaded")
    }

    public func typedThrowing() throws(CancellationError) -> some View { Text("typed") }

    public func rethrowing(_ make: () throws -> String) rethrows -> some View { Text(try make()) }

    public static func badge(_ count: Int) -> some View { Text(verbatim: "badge \(count)") }
}

/// The requirement makes the body a view builder, without the attribute.
public struct Card: ViewModifier {
    var bordered: Bool
    public init(bordered: Bool) { self.bordered = bordered }

    public func body(content: Content) -> some View {
        let inset = 8.0
        if bordered {
            content.padding(inset).border(Color.gray)
        } else {
            content.padding(inset)
        }
        Divider()
    }
}

public struct Dimmed: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// A builder requirement turned off by an explicit `return`.
public struct Inset: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        let inset = 8.0
        return content.padding(inset)
    }
}

extension View {
    public func card() -> some View { modifier(Card(bordered: true)) }
}

public struct Tally {
    public var count = 0
    public init() {}
    public mutating func next() -> some View {
        count += 1
        return Text(verbatim: "\(count)")
    }
    public func add(to total: inout Int) -> some View {
        total += 1
        return Text(verbatim: "\(total)")
    }
}

public actor Renderer {
    var frames = 0
    public init() {}
    public func render() -> some View {
        frames += 1
        return Text(verbatim: "\(frames)")
    }
}

public func freeView() -> some View { Divider().padding(.horizontal) }

/// An explicit `return` turns the result builder off: these bodies are ordinary ones.
public struct Returning: View {
    public init() {}
    public var body: some View {
        let title = "returning"
        return Text(verbatim: title)
    }

    @ViewBuilder public func row() -> some View {
        return Text(verbatim: "row")
    }
}
#endif
