// OWNER: ENG-09
//
// Proves the example host's RunnerTests target sees the shared fixture trees and that ENG-05's media
// decodes on the simulator: frame 160 of frame_counter_1080p30 carries barcode 160.
//
// RunnerTests is an Xcode synchronized folder: every file under example/ios/RunnerTests is part of
// the target, so native tickets add test directories (Glue/, Media/, ...) without touching the
// pbxproj. The fixture trees are folder references in the test bundle (example/ios/TestFixtures/*
// are relative symlinks resolved when Xcode copies them):
//
//   engine/      packages/vwish_editor_engine/test_fixtures      (media/, manifest.json)
//   core/        packages/vwish_editor_core/test/fixtures
//   engine_api/  packages/vwish_editor_engine_api/test_fixtures

import AVFoundation
import XCTest

/// The shared fixture trees inside the RunnerTests bundle.
enum TestFixtures {
    enum Tree: String, CaseIterable {
        case engine, core, engineApi = "engine_api"
    }

    private final class Anchor {}

    /// The root directory of [tree] in the test bundle.
    static func root(_ tree: Tree) -> URL? {
        guard let base = Bundle(for: Anchor.self).resourceURL else { return nil }
        let url = base.appendingPathComponent(tree.rawValue, isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? url : nil
    }

    /// A file inside [tree] (relative path such as "media/manifest.json").
    static func url(_ tree: Tree, _ relativePath: String) -> URL? {
        guard let url = root(tree)?.appendingPathComponent(relativePath),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

final class FixtureHarnessTests: XCTestCase {
    func testEveryFixtureTreeIsInTheBundle() throws {
        for tree in TestFixtures.Tree.allCases {
            let root = try XCTUnwrap(TestFixtures.root(tree), "fixture tree \(tree.rawValue) missing")
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(entries.isEmpty, "fixture tree \(tree.rawValue) is empty")
        }
        XCTAssertNotNil(TestFixtures.url(.engine, "media/frame_counter_1080p30.mp4"))
        XCTAssertNotNil(TestFixtures.url(.core, "vectors"))
    }

    func testManifestParses() throws {
        let url = try XCTUnwrap(TestFixtures.url(.engine, "media/manifest.json"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let manifest = try XCTUnwrap(json as? [String: Any])
        XCTAssertNotNil(manifest["files"])
    }

    func testFrameCounterDecodesOnTheSimulator() throws {
        let url = try XCTUnwrap(TestFixtures.url(.engine, "media/frame_counter_1080p30.mp4"))
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // The middle of frame 160 (30 fps CFR).
        let time = CMTime(value: 160 * 2 + 1, timescale: 60)
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        let reading = FrameBarcode.read(cgImage: image)
        XCTAssertEqual(reading.status, .ok)
        XCTAssertEqual(reading.index, 160)
    }
}
