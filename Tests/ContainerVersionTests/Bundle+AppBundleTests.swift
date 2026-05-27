//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import SystemPackage
import Testing

@testable import ContainerVersion

struct BundleAppBundleTests {
    @Test func returnsNilForUnixInstallPath() {
        // /usr/local/bin/container — no .app bundle in the hierarchy
        let path = FilePath("/usr/local/bin/container")
        #expect(Bundle.appBundle(executablePath: path) == nil)
    }

    @Test func returnsBundleForAppBundleExecutable() throws {
        // Build a minimal Foo.app bundle on disk — Bundle(url:) requires the directory to exist.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = tmp.appendingPathComponent("Foo.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try Data("<plist version=\"1.0\"><dict/></plist>".utf8)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))

        let executablePath = FilePath(macOSURL.path(percentEncoded: false))
            .appending(FilePath.Component("Foo"))
        let bundle = Bundle.appBundle(executablePath: executablePath)
        #expect(bundle != nil)
        #expect(bundle?.bundleURL.lastPathComponent == "Foo.app")
    }

    @Test func returnsBundleForSymlinkedExecutable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundleURL = tmp.appendingPathComponent("Foo.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try Data("<plist version=\"1.0\"><dict/></plist>".utf8)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
        let executableURL = macOSURL.appendingPathComponent("Foo")
        try Data().write(to: executableURL)

        // Symlink outside the bundle pointing at the real executable
        let symlinkURL = tmp.appendingPathComponent("foo-link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: executableURL)

        let bundle = Bundle.appBundle(executablePath: FilePath(symlinkURL.path(percentEncoded: false)))
        #expect(bundle != nil)
        #expect(bundle?.bundleURL.lastPathComponent == "Foo.app")
    }

    @Test func returnsNilWhenTooShallow() {
        // Only one component above executable — can't be a bundle
        let path = FilePath("/Foo.app/binary")
        #expect(Bundle.appBundle(executablePath: path) == nil)
    }

    @Test func returnsNilWhenThirdAncestorLacksAppExtension() {
        // Parent hierarchy exists but doesn't end in .app
        let path = FilePath("/opt/tools/bin/helper")
        #expect(Bundle.appBundle(executablePath: path) == nil)
    }
}
