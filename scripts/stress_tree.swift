#!/usr/bin/swift

import Foundation

enum StressTreeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case rootMissing(String)

    var description: String {
        switch self {
        case .invalidArguments(let message):
            return message
        case .rootMissing(let root):
            return "Root does not exist: \(root)"
        }
    }
}

struct Config {
    let command: Command
    let root: URL

    enum Command {
        case create(files: Int, fileSize: Int, fanout: Int)
        case mutate(count: Int, bytes: Int)
        case stats
        case clean
    }
}

private let fileManager = FileManager.default

func main() throws {
    let config = try parse(arguments: CommandLine.arguments)

    switch config.command {
    case .create(let files, let fileSize, let fanout):
        try createTree(root: config.root, files: files, fileSize: fileSize, fanout: fanout)
    case .mutate(let count, let bytes):
        try mutateTree(root: config.root, count: count, bytes: bytes)
    case .stats:
        try printStats(root: config.root)
    case .clean:
        try cleanTree(root: config.root)
    }
}

func parse(arguments: [String]) throws -> Config {
    guard arguments.count >= 3 else {
        throw StressTreeError.invalidArguments(usage())
    }

    let commandName = arguments[1]
    var rootPath: String?
    var files = 100_000
    var fileSize = 4_096
    var fanout = 250
    var mutateCount = 1_000
    var mutateBytes = 1_048_576

    var index = 2
    while index < arguments.count {
        let argument = arguments[index]
        guard index + 1 < arguments.count else {
            throw StressTreeError.invalidArguments("Missing value for \(argument)\n\n\(usage())")
        }

        let value = arguments[index + 1]
        switch argument {
        case "--root":
            rootPath = value
        case "--files":
            files = try parsePositiveInt(value, name: "--files")
        case "--file-size":
            fileSize = try parsePositiveInt(value, name: "--file-size")
        case "--fanout":
            fanout = try parsePositiveInt(value, name: "--fanout")
        case "--count":
            mutateCount = try parsePositiveInt(value, name: "--count")
        case "--bytes":
            mutateBytes = try parsePositiveInt(value, name: "--bytes")
        default:
            throw StressTreeError.invalidArguments("Unknown argument: \(argument)\n\n\(usage())")
        }

        index += 2
    }

    guard let rootPath else {
        throw StressTreeError.invalidArguments("Missing --root\n\n\(usage())")
    }

    let root = URL(fileURLWithPath: rootPath).standardizedFileURL
    let command: Config.Command

    switch commandName {
    case "create":
        command = .create(files: files, fileSize: fileSize, fanout: fanout)
    case "mutate":
        command = .mutate(count: mutateCount, bytes: mutateBytes)
    case "stats":
        command = .stats
    case "clean":
        command = .clean
    default:
        throw StressTreeError.invalidArguments("Unknown command: \(commandName)\n\n\(usage())")
    }

    return Config(command: command, root: root)
}

func parsePositiveInt(_ value: String, name: String) throws -> Int {
    guard let parsed = Int(value), parsed > 0 else {
        throw StressTreeError.invalidArguments("Expected a positive integer for \(name), got \(value)")
    }
    return parsed
}

func usage() -> String {
    """
    Usage:
      swift scripts/stress_tree.swift create --root <path> [--files N] [--file-size bytes] [--fanout N]
      swift scripts/stress_tree.swift mutate --root <path> [--count N] [--bytes bytes]
      swift scripts/stress_tree.swift stats --root <path>
      swift scripts/stress_tree.swift clean --root <path>
    """
}

func createTree(root: URL, files: Int, fileSize: Int, fanout: Int) throws {
    let datasetRoot = root.appendingPathComponent("dataset", isDirectory: true)
    let metadataRoot = root.appendingPathComponent(".stress-tree", isDirectory: true)
    let metadataURL = metadataRoot.appendingPathComponent("manifest.json")

    try fileManager.createDirectory(at: datasetRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: metadataRoot, withIntermediateDirectories: true)

    let start = Date()
    let firstPassPath = datasetRoot.path

    for index in 0..<files {
        let bucket = index / fanout
        let directoryURL = URL(fileURLWithPath: firstPassPath)
            .appendingPathComponent(String(format: "bucket-%06d", bucket), isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileURL = directoryURL.appendingPathComponent(String(format: "file-%08d.dat", index))
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        try writeDeterministicFile(at: fileURL, bytes: fileSize, seed: UInt8(index % 251))

        if index > 0 && index % 10_000 == 0 {
            print("created \(index) files...")
        }
    }

    let manifest = Manifest(
        createdAt: ISO8601DateFormatter().string(from: start),
        files: files,
        fileSize: fileSize,
        fanout: fanout,
        datasetRoot: datasetRoot.path
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifestData = try encoder.encode(manifest)
    try manifestData.write(to: metadataURL, options: .atomic)

    let elapsed = Date().timeIntervalSince(start)
    print("created \(files) files at \(datasetRoot.path)")
    print("logical bytes: \(Int64(files) * Int64(fileSize))")
    print(String(format: "elapsed: %.2fs", elapsed))
}

func mutateTree(root: URL, count: Int, bytes: Int) throws {
    let manifest = try loadManifest(root: root)
    let datasetRoot = URL(fileURLWithPath: manifest.datasetRoot, isDirectory: true)
    let start = Date()
    var mutated = 0
    let limit = min(count, manifest.files)

    for index in 0..<limit {
        let bucket = index / manifest.fanout
        let directoryURL = datasetRoot.appendingPathComponent(String(format: "bucket-%06d", bucket), isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent(String(format: "file-%08d.dat", index))
        try appendDeterministicBytes(to: fileURL, bytes: bytes, seed: UInt8((index + 17) % 251))
        mutated += 1
    }

    let elapsed = Date().timeIntervalSince(start)
    print("mutated \(mutated) files under \(datasetRoot.path)")
    print("bytes added per file: \(bytes)")
    print(String(format: "elapsed: %.2fs", elapsed))
}

func printStats(root: URL) throws {
    let manifest = try loadManifest(root: root)
    let datasetRoot = URL(fileURLWithPath: manifest.datasetRoot, isDirectory: true)
    let bucketCount = Int(ceil(Double(manifest.files) / Double(manifest.fanout)))
    print("root: \(root.path)")
    print("dataset: \(datasetRoot.path)")
    print("files: \(manifest.files)")
    print("file size: \(manifest.fileSize)")
    print("fanout: \(manifest.fanout)")
    print("bucket directories: \(bucketCount)")
    print("logical bytes: \(Int64(manifest.files) * Int64(manifest.fileSize))")
    print("created at: \(manifest.createdAt)")
}

func cleanTree(root: URL) throws {
    guard fileManager.fileExists(atPath: root.path) else {
        print("nothing to remove at \(root.path)")
        return
    }

    try fileManager.removeItem(at: root)
    print("removed \(root.path)")
}

func loadManifest(root: URL) throws -> Manifest {
    let metadataURL = root
        .appendingPathComponent(".stress-tree", isDirectory: true)
        .appendingPathComponent("manifest.json")

    guard fileManager.fileExists(atPath: metadataURL.path) else {
        throw StressTreeError.rootMissing(root.path)
    }

    let data = try Data(contentsOf: metadataURL)
    return try JSONDecoder().decode(Manifest.self, from: data)
}

func writeDeterministicFile(at url: URL, bytes: Int, seed: UInt8) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try writePattern(to: handle, bytes: bytes, seed: seed)
    try handle.close()
}

func appendDeterministicBytes(to url: URL, bytes: Int, seed: UInt8) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try writePattern(to: handle, bytes: bytes, seed: seed)
    try handle.close()
}

func writePattern(to handle: FileHandle, bytes: Int, seed: UInt8) throws {
    let chunkSize = min(64 * 1024, max(1, bytes))
    let chunk = Data(repeating: seed, count: chunkSize)
    var remaining = bytes

    while remaining > 0 {
        let writeCount = min(chunk.count, remaining)
        try handle.write(contentsOf: chunk.prefix(writeCount))
        remaining -= writeCount
    }
}

struct Manifest: Codable {
    let createdAt: String
    let files: Int
    let fileSize: Int
    let fanout: Int
    let datasetRoot: String
}

do {
    try main()
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
