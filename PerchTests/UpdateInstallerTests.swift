import Foundation
import Testing
@testable import Perch

struct UpdateArchiveTests {
    @Test(arguments: ["../outside", "/tmp/outside", "Perch.app/../outside", "Perch.app//file"])
    func rejectsPathsOutsideTheStagedApp(name: String) throws {
        let archive = try writeArchive(localName: name, directoryName: name)
        defer { try? FileManager.default.removeItem(at: archive) }
        #expect(throws: UpdateInstallError.self) {
            try ZipInspector.inspect(archive, size: Int64(Data(contentsOf: archive).count))
        }
    }

    @Test func rejectsLocalHeaderPathHiddenBySafeDirectoryEntry() throws {
        let archive = try writeArchive(localName: "../escape", directoryName: "Perch.app/file")
        defer { try? FileManager.default.removeItem(at: archive) }
        #expect(throws: UpdateInstallError.self) {
            try ZipInspector.inspect(archive, size: Int64(Data(contentsOf: archive).count))
        }
    }

    @Test func acceptsMatchingInBundleHeaderNames() throws {
        let archive = try writeArchive(localName: "Perch.app/file", directoryName: "Perch.app/file")
        defer { try? FileManager.default.removeItem(at: archive) }
        try ZipInspector.inspect(archive, size: Int64(Data(contentsOf: archive).count))
    }

    /// One stored empty file, with independently controlled local and central names.
    private func writeArchive(localName: String, directoryName: String) throws -> URL {
        var data = Data()
        func u16(_ value: UInt16) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(truncatingIfNeeded: value >> 16)) }
        u32(0x04034b50); u16(20); u16(0); u16(0); u16(0); u16(0)
        u32(0); u32(0); u32(0); u16(UInt16(localName.utf8.count)); u16(0)
        data.append(contentsOf: localName.utf8)
        let centralOffset = UInt32(data.count)
        u32(0x02014b50); u16(0x0314); u16(20); u16(0); u16(0); u16(0); u16(0)
        u32(0); u32(0); u32(0); u16(UInt16(directoryName.utf8.count)); u16(0); u16(0)
        u16(0); u16(0); u32(0o100644 << 16); u32(0)
        data.append(contentsOf: directoryName.utf8)
        let centralSize = UInt32(data.count) - centralOffset
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1)
        u32(centralSize); u32(centralOffset); u16(0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: url)
        return url
    }
}
