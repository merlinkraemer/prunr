import Foundation

/// The app process is the unit-test host: XCTest loaded it to run tests.
enum TestHost {
    static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
    }()
}
