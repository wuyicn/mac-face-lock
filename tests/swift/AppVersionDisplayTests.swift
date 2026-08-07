import Foundation

private enum TestFailure: Error {
    case assertion(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.assertion(message)
    }
}

@main
struct AppVersionDisplayTests {
    static func main() throws {
        try require(
            AppVersionDisplay.text(from: "0.2.0") == "v0.2.0",
            "marketing version should use the selected v-prefix format"
        )
        try require(
            AppVersionDisplay.text(from: " 0.2.0 ") == "v0.2.0",
            "version metadata should be trimmed"
        )
        try require(
            AppVersionDisplay.text(from: nil) == nil,
            "missing metadata must be hidden"
        )
        try require(
            AppVersionDisplay.text(from: "   ") == nil,
            "blank metadata must be hidden"
        )
        try require(
            AppVersionDisplay.text(from: 200) == nil,
            "non-string metadata must be hidden"
        )
        print("App version display tests passed")
    }
}
