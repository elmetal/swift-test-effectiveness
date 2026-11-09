import Foundation

/// Placeholders in a custom test command, replaced for each run.
enum CommandTemplate {
    /// The number of the worker running the command, `1` to `--jobs`. Lets each worker use its own
    /// simulator, e.g. `-destination 'platform=iOS Simulator,name=STE-{job}'`.
    static let job = "{job}"
    /// A path for this run's result bundle that does not exist yet, e.g.
    /// `-resultBundlePath {result-bundle}`. xcodebuild names its default bundles by the second the
    /// run started, so runs that start together collide, and it refuses an existing path.
    static let resultBundle = "{result-bundle}"

    static func expand(_ command: String, tests: [TestSelector]?, job: Int, resultBundle: URL) -> String {
        TestSelection.expand(command, tests: tests)
            .replacingOccurrences(of: Self.job, with: String(job))
            .replacingOccurrences(of: Self.resultBundle, with: TestSelection.shellQuoted(resultBundle.path))
    }
}
