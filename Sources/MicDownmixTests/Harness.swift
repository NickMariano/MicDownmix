import Foundation

/// A deliberately small test harness.
///
/// Neither XCTest nor swift-testing ships with Command Line Tools, and this project has to build
/// without Xcode. Rather than lose the tests that pin down the mixing behaviour, they run as an
/// ordinary executable: `swift run MicDownmixTests`, exit status 0 on success.
enum Harness {
    nonisolated(unsafe) static var currentScope = ""
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0
}

func scope(_ name: String) {
    Harness.currentScope = name
}

func expect(
    _ condition: Bool,
    _ detail: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    Harness.checks += 1
    guard !condition else { return }
    let suffix = detail().isEmpty ? "" : " (\(detail()))"
    Harness.failures.append("\(Harness.currentScope)\(suffix)\n      at \(file):\(line)")
}

func run(_ cases: [@Sendable () -> Void]) -> Never {
    var scopesSeen: [String] = []
    for testCase in cases {
        let failuresBefore = Harness.failures.count
        testCase()
        let name = Harness.currentScope
        scopesSeen.append(name)
        let passed = Harness.failures.count == failuresBefore
        print("\(passed ? "  ok" : "FAIL")  \(name)")
    }

    print("")
    if Harness.failures.isEmpty {
        print("\(scopesSeen.count) tests, \(Harness.checks) checks, all passed")
        exit(0)
    }

    print("\(Harness.failures.count) failure(s):")
    for failure in Harness.failures {
        print("  - \(failure)")
    }
    exit(1)
}
