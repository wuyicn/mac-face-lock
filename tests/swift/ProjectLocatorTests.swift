import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.assertion(message)
    }
}

private func expectError(
    _ expected: ProjectLocatorError,
    operation: () throws -> Void
) throws {
    do {
        try operation()
        throw TestFailure.assertion("expected \(expected), but operation succeeded")
    } catch let error as ProjectLocatorError {
        try require(error == expected, "expected \(expected), got \(error)")
    }
}

private func makeProjectRoot(
    includeConfiguration: Bool = true,
    includeDataDirectory: Bool = true
) throws -> URL {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("mac-face-lock-project-locator-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    if includeConfiguration {
        let configuration = root.appendingPathComponent("config/config.json")
        try fileManager.createDirectory(
            at: configuration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: configuration)
    }

    if includeDataDirectory {
        try fileManager.createDirectory(
            at: root.appendingPathComponent("data", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    return root
}

@main
struct ProjectLocatorTests {
    static func main() throws {
        try testMissingProjectArgument()
        try testRelativeProjectPath()
        try testValidProjectRoot()
        try testMissingProjectDirectory()
        try testMissingConfiguration()
        try testCreatesProjectDataDirectory()
        try testRejectsDataSymlinkOutsideProject()
        try testReturnsResolvedDataURLForInternalSymlink()
        try testResolvesSymlinkedProjectRoot()
        print("Project locator tests passed")
    }

    private static func testMissingProjectArgument() throws {
        try expectError(.missingProjectArgument) {
            _ = try ProjectLocator.locate(arguments: ["MacFaceLock"])
        }
    }

    private static func testRelativeProjectPath() throws {
        try expectError(.relativeProjectPath("relative")) {
            _ = try ProjectLocator.locate(arguments: ["MacFaceLock", "relative"])
        }
    }

    private static func testValidProjectRoot() throws {
        let validRoot = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: validRoot) }

        let located = try ProjectLocator.locate(arguments: ["MacFaceLock", validRoot.path])

        try require(
            located.projectURL.standardizedFileURL == validRoot.standardizedFileURL,
            "locator did not return the validated project root"
        )
        try require(
            located.dataURL == validRoot.appendingPathComponent("data", isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL,
            "locator did not return the validated data directory"
        )
    }

    private static func testMissingProjectDirectory() throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-face-lock-missing-\(UUID().uuidString)", isDirectory: true)
        try expectError(.projectDirectoryUnavailable(missingRoot.path)) {
            _ = try ProjectLocator.locate(arguments: ["MacFaceLock", missingRoot.path])
        }
    }

    private static func testMissingConfiguration() throws {
        let root = try makeProjectRoot(includeConfiguration: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationPath = root.appendingPathComponent("config/config.json").path

        try expectError(.configurationUnavailable(configurationPath)) {
            _ = try ProjectLocator.locate(arguments: ["MacFaceLock", root.path])
        }
    }

    private static func testCreatesProjectDataDirectory() throws {
        let root = try makeProjectRoot(includeDataDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try ProjectLocator.locate(arguments: ["MacFaceLock", root.path])

        var isDirectory: ObjCBool = false
        let dataPath = root.appendingPathComponent("data", isDirectory: true).path
        try require(
            FileManager.default.fileExists(atPath: dataPath, isDirectory: &isDirectory),
            "locator did not create the project data directory"
        )
        try require(isDirectory.boolValue, "created data path is not a directory")
    }

    private static func testRejectsDataSymlinkOutsideProject() throws {
        let fileManager = FileManager.default
        let root = try makeProjectRoot(includeDataDirectory: false)
        let externalData = fileManager.temporaryDirectory
            .appendingPathComponent("mac-face-lock-external-data-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: externalData, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: externalData)
        }
        let dataURL = root.appendingPathComponent("data", isDirectory: true)
        try fileManager.createSymbolicLink(at: dataURL, withDestinationURL: externalData)

        try expectError(.dataDirectoryUnavailable(dataURL.path)) {
            _ = try ProjectLocator.locate(arguments: ["MacFaceLock", root.path])
        }
        let externalContents = try fileManager.contentsOfDirectory(atPath: externalData.path)
        try require(
            externalContents.isEmpty,
            "locator wrote through an external data symlink"
        )
    }

    private static func testReturnsResolvedDataURLForInternalSymlink() throws {
        let fileManager = FileManager.default
        let root = try makeProjectRoot(includeDataDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        let ownedData = root.appendingPathComponent("project-data", isDirectory: true)
        try fileManager.createDirectory(at: ownedData, withIntermediateDirectories: false)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("data", isDirectory: true),
            withDestinationURL: ownedData
        )

        let located = try ProjectLocator.locate(arguments: ["MacFaceLock", root.path])

        try require(
            located.projectURL == root.resolvingSymlinksInPath().standardizedFileURL,
            "locator rejected a project-owned data symlink"
        )
        try require(
            located.dataURL == ownedData.resolvingSymlinksInPath().standardizedFileURL,
            "locator did not return the internal data symlink's real target"
        )
    }

    private static func testResolvesSymlinkedProjectRoot() throws {
        let fileManager = FileManager.default
        let root = try makeProjectRoot()
        let aliasParent = fileManager.temporaryDirectory
            .appendingPathComponent("mac-face-lock-project-alias-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: aliasParent, withIntermediateDirectories: true)
        let alias = aliasParent.appendingPathComponent("project", isDirectory: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: root)
        defer {
            try? fileManager.removeItem(at: aliasParent)
            try? fileManager.removeItem(at: root)
        }

        let located = try ProjectLocator.locate(arguments: ["MacFaceLock", alias.path])

        try require(
            located.projectURL == root.resolvingSymlinksInPath().standardizedFileURL,
            "locator did not resolve the real project root"
        )
        try require(
            located.dataURL == root.appendingPathComponent("data", isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL,
            "locator did not return data under the real project root"
        )
    }
}
