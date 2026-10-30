import Foundation
import Testing
@testable import Perch

struct AirDropArrivalsTests {
    @Test func onlySharingdQuarantineCounts() {
        // Real values from files in ~/Downloads on this Mac.
        let airdrop = AirDropQuarantine.transferDate("0081;6abb88a7;sharingd;CDA4C03F-66C0-42CE-B7B1-0B808F43BA25")
        #expect(airdrop?.key == "6abb88a7")
        #expect(airdrop?.date == Date(timeIntervalSince1970: 0x6abb88a7))
        #expect(AirDropQuarantine.transferDate("0083;6abb88a7;Arc;30EF863F-CD8F-4ACB-9040-8EE885497743") == nil)
        #expect(AirDropQuarantine.transferDate("garbage") == nil)
    }

    @Test func groupsATransferAndWaitsForItToSettle() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("perch-airdrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("old.pdf", in: folder, quarantine: nil)

        var reported: [AirDropArrivals.Transfer] = []
        let arrivals = AirDropArrivals(folder: folder) { reported.append($0) }
        arrivals.start() // the file already there is not an arrival
        defer { arrivals.stop() }

        let now = Date()
        let hex = String(UInt64(now.timeIntervalSince1970), radix: 16)
        try write("b.jpg", in: folder, quarantine: "0081;\(hex);sharingd;A")
        try write("a.jpg", in: folder, quarantine: "0081;\(hex);sharingd;B")
        try write("browser.zip", in: folder, quarantine: "0081;\(hex);Arc;C")
        let stale = String(UInt64(now.timeIntervalSince1970) - 3600, radix: 16)
        try write("restored.jpg", in: folder, quarantine: "0081;\(stale);sharingd;D")

        arrivals.scan(now: now)
        #expect(reported.isEmpty) // still settling

        arrivals.flush(now: now.addingTimeInterval(AirDropArrivals.settle))
        #expect(reported.map(\.key) == [hex])
        #expect(reported.first?.files.map(\.lastPathComponent) == ["a.jpg", "b.jpg"])

        arrivals.scan(now: now.addingTimeInterval(5))
        #expect(reported.count == 1) // reported once
    }

    private func write(_ name: String, in folder: URL, quarantine: String?) throws {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        guard let quarantine else { return }
        let value = Data(quarantine.utf8)
        let status = url.withUnsafeFileSystemRepresentation { path in
            value.withUnsafeBytes { setxattr(path, AirDropQuarantine.attribute, $0.baseAddress, value.count, 0, 0) }
        }
        #expect(status == 0)
    }
}
