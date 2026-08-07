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

private func makeTemporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSourceRoot() throws -> URL {
    let root = try makeTemporaryDirectory(named: "mac-face-lock-environment-source")
    let configurationURL = root.appendingPathComponent("config/config.json")
    try FileManager.default.createDirectory(
        at: configurationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: configurationURL)
    return root
}

private func makeReleaseFixture() throws -> (bundle: URL, applicationSupport: URL) {
    let root = try makeTemporaryDirectory(named: "mac-face-lock-environment-release")
    let bundle = root.appendingPathComponent("Mac Face Lock.app", isDirectory: true)
    let defaultsURL = bundle.appendingPathComponent(
        "Contents/Resources/defaults/config.json"
    )
    try FileManager.default.createDirectory(
        at: defaultsURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("{\"source\":\"bundled\"}".utf8).write(to: defaultsURL)

    let applicationSupport = root.appendingPathComponent(
        "Library/Application Support",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: applicationSupport,
        withIntermediateDirectories: true
    )
    return (bundle, applicationSupport)
}

@main
struct AppEnvironmentTests {
    static func main() throws {
        try testNoArgumentsSelectReleaseMode()
        try testExplicitSourceRootPreservesRepositoryLayout()
        try testLegacySourceRootPreservesRepositoryLayout()
        try testReleaseCopiesDefaultConfigurationOnlyWhenMissing()
        try testReleaseRejectsResourcesSymlinkOutsideBundle()
        try testReleaseRejectsExistingConfigurationDirectory()
        try testReleaseRejectsConfigurationSymlinkOutsideSupport()
        try testReleaseRejectsSupportSymlinkOutsideApplicationSupport()
        print("App environment tests passed")
    }

    private static func testNoArgumentsSelectReleaseMode() throws {
        let fixture = try makeReleaseFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.bundle.deletingLastPathComponent()
            )
        }

        let release = try AppEnvironment.resolve(
            arguments: ["MacFaceLock"],
            bundleURL: fixture.bundle,
            applicationSupportURL: fixture.applicationSupport,
            fileManager: .default
        )

        let expectedResources = fixture.bundle
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let expectedSupport = fixture.applicationSupport
            .appendingPathComponent("Mac Face Lock", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        try require(release.mode == .release, "no-argument launch must select release mode")
        try require(
            release.supportURL.lastPathComponent == "Mac Face Lock",
            "release data must use the product support directory"
        )
        try require(
            release.resourcesURL == expectedResources,
            "release resources did not resolve inside the application bundle"
        )
        try require(release.supportURL == expectedSupport, "release support path is incorrect")
        try require(
            release.configURL == expectedSupport.appendingPathComponent("config/config.json"),
            "release config path is incorrect"
        )
        try require(
            release.dataURL == expectedSupport.appendingPathComponent("data", isDirectory: true),
            "release data path is incorrect"
        )
        try require(
            release.logsURL == expectedSupport.appendingPathComponent("logs", isDirectory: true),
            "release logs path is incorrect"
        )
        try require(
            release.runtimeExecutableURL
                == fixture.bundle.appendingPathComponent("Contents/MacOS/MacFaceLock"),
            "release runtime did not use the single application identity"
        )
    }

    private static func testExplicitSourceRootPreservesRepositoryLayout() throws {
        let root = try makeSourceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try AppEnvironment.resolve(
            arguments: ["MacFaceLock", "--source-root", root.path],
            bundleURL: URL(fileURLWithPath: "/Applications/Mac Face Lock.app"),
            applicationSupportURL: URL(fileURLWithPath: "/tmp/unused-application-support"),
            fileManager: .default
        )
        try require(source.mode == .source, "--source-root did not select source mode")
        try require(source.resourcesURL == root, "source resources did not use the repository root")
        try require(source.supportURL == root, "source support did not use the repository root")
        try require(
            source.configURL == root.appendingPathComponent("config/config.json"),
            "source config path changed"
        )
        try require(
            source.dataURL == root.appendingPathComponent("data", isDirectory: true),
            "source data path changed"
        )
        try require(
            source.logsURL == root.appendingPathComponent("logs", isDirectory: true),
            "source logs path changed"
        )
        try require(
            source.runtimeExecutableURL == root.appendingPathComponent(".venv/bin/python"),
            "source runtime path changed"
        )
    }

    private static func testLegacySourceRootPreservesRepositoryLayout() throws {
        let root = try makeSourceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try AppEnvironment.resolve(
            arguments: ["MacFaceLock", root.path],
            bundleURL: URL(fileURLWithPath: "/Applications/Mac Face Lock.app"),
            applicationSupportURL: URL(fileURLWithPath: "/tmp/unused-application-support"),
            fileManager: .default
        )
        try require(source.mode == .source, "legacy path argument did not select source mode")
        try require(source.resourcesURL == root, "legacy source resources changed")
        try require(
            source.dataURL == root.appendingPathComponent("data", isDirectory: true),
            "legacy source data path changed"
        )
    }

    private static func testReleaseCopiesDefaultConfigurationOnlyWhenMissing() throws {
        let fixture = try makeReleaseFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.bundle.deletingLastPathComponent()
            )
        }

        let first = try AppEnvironment.resolve(
            arguments: ["MacFaceLock"],
            bundleURL: fixture.bundle,
            applicationSupportURL: fixture.applicationSupport,
            fileManager: .default
        )
        let copiedConfiguration = try Data(contentsOf: first.configURL)
        try require(
            copiedConfiguration == Data("{\"source\":\"bundled\"}".utf8),
            "release did not copy the bundled default configuration"
        )
        try require(
            FileManager.default.fileExists(atPath: first.dataURL.path),
            "release did not create the data directory"
        )
        try require(
            FileManager.default.fileExists(atPath: first.logsURL.path),
            "release did not create the logs directory"
        )

        let customerConfiguration = Data("{\"source\":\"customer\"}".utf8)
        try customerConfiguration.write(to: first.configURL)
        let bundledDefault = fixture.bundle.appendingPathComponent(
            "Contents/Resources/defaults/config.json"
        )
        try Data("{\"source\":\"updated-bundle\"}".utf8).write(to: bundledDefault)

        let second = try AppEnvironment.resolve(
            arguments: ["MacFaceLock"],
            bundleURL: fixture.bundle,
            applicationSupportURL: fixture.applicationSupport,
            fileManager: .default
        )
        let preservedConfiguration = try Data(contentsOf: second.configURL)
        try require(
            preservedConfiguration == customerConfiguration,
            "release overwrote the existing customer configuration"
        )
    }

    private static func testReleaseRejectsResourcesSymlinkOutsideBundle() throws {
        let fixture = try makeReleaseFixture()
        let fixtureRoot = fixture.bundle.deletingLastPathComponent()
        let external = try makeTemporaryDirectory(named: "mac-face-lock-external-resources")
        defer {
            try? FileManager.default.removeItem(at: fixtureRoot)
            try? FileManager.default.removeItem(at: external)
        }

        let externalDefault = external.appendingPathComponent("defaults/config.json")
        try FileManager.default.createDirectory(
            at: externalDefault.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"source\":\"external\"}".utf8).write(to: externalDefault)

        let resourcesURL = fixture.bundle.appendingPathComponent(
            "Contents/Resources",
            isDirectory: true
        )
        try FileManager.default.removeItem(at: resourcesURL)
        try FileManager.default.createSymbolicLink(
            at: resourcesURL,
            withDestinationURL: external
        )

        do {
            _ = try AppEnvironment.resolve(
                arguments: ["MacFaceLock"],
                bundleURL: fixture.bundle,
                applicationSupportURL: fixture.applicationSupport,
                fileManager: .default
            )
            throw TestFailure.assertion("escaping Resources symlink was accepted")
        } catch AppEnvironmentError.resourcesDirectoryUnavailable {
            return
        }
    }

    private static func testReleaseRejectsExistingConfigurationDirectory() throws {
        let fixture = try makeReleaseFixture()
        let fixtureRoot = fixture.bundle.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let configurationURL = fixture.applicationSupport.appendingPathComponent(
            "Mac Face Lock/config/config.json",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: configurationURL,
            withIntermediateDirectories: true
        )

        do {
            _ = try AppEnvironment.resolve(
                arguments: ["MacFaceLock"],
                bundleURL: fixture.bundle,
                applicationSupportURL: fixture.applicationSupport,
                fileManager: .default
            )
            throw TestFailure.assertion("existing configuration directory was accepted")
        } catch let error as AppEnvironmentError {
            try require(
                error == .configurationFileUnavailable(configurationURL.path),
                "configuration-directory collision returned the wrong error: \(error)"
            )
        }
    }

    private static func testReleaseRejectsConfigurationSymlinkOutsideSupport() throws {
        let fixture = try makeReleaseFixture()
        let fixtureRoot = fixture.bundle.deletingLastPathComponent()
        let external = try makeTemporaryDirectory(named: "mac-face-lock-external-config")
        defer {
            try? FileManager.default.removeItem(at: fixtureRoot)
            try? FileManager.default.removeItem(at: external)
        }

        let externalConfigurationURL = external.appendingPathComponent("config.json")
        let externalConfiguration = Data("{\"source\":\"external-customer\"}".utf8)
        try externalConfiguration.write(to: externalConfigurationURL)

        let configurationURL = fixture.applicationSupport.appendingPathComponent(
            "Mac Face Lock/config/config.json"
        )
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: configurationURL,
            withDestinationURL: externalConfigurationURL
        )

        do {
            _ = try AppEnvironment.resolve(
                arguments: ["MacFaceLock"],
                bundleURL: fixture.bundle,
                applicationSupportURL: fixture.applicationSupport,
                fileManager: .default
            )
            throw TestFailure.assertion("escaping configuration symlink was accepted")
        } catch let error as AppEnvironmentError {
            try require(
                error == .configurationFileUnavailable(configurationURL.path),
                "escaping configuration symlink returned the wrong error: \(error)"
            )
        }
        let preservedExternalConfiguration = try Data(
            contentsOf: externalConfigurationURL
        )
        try require(
            preservedExternalConfiguration == externalConfiguration,
            "release modified a configuration outside its support root"
        )
    }

    private static func testReleaseRejectsSupportSymlinkOutsideApplicationSupport() throws {
        let fixture = try makeReleaseFixture()
        let fixtureRoot = fixture.bundle.deletingLastPathComponent()
        let external = try makeTemporaryDirectory(named: "mac-face-lock-external-support")
        defer {
            try? FileManager.default.removeItem(at: fixtureRoot)
            try? FileManager.default.removeItem(at: external)
        }

        let supportURL = fixture.applicationSupport
            .appendingPathComponent("Mac Face Lock", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: supportURL, withDestinationURL: external)

        do {
            _ = try AppEnvironment.resolve(
                arguments: ["MacFaceLock"],
                bundleURL: fixture.bundle,
                applicationSupportURL: fixture.applicationSupport,
                fileManager: .default
            )
            throw TestFailure.assertion("escaping support-directory symlink was accepted")
        } catch let error as AppEnvironmentError {
            try require(
                error == .supportDirectoryUnavailable(supportURL.path),
                "escaping support-directory symlink returned the wrong error: \(error)"
            )
        }
        let externalContents = try FileManager.default.contentsOfDirectory(atPath: external.path)
        try require(
            externalContents.isEmpty,
            "release wrote through an escaping support-directory symlink"
        )
    }
}
