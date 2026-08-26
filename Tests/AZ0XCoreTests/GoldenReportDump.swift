import XCTest
@testable import AZ0XCore

/// Writes one representative record to disk so the report can be read as a document, not as a set
/// of substring assertions. Skipped unless AZ0X_DUMP is set; it is a tool, not a check.
final class GoldenReportDump: XCTestCase {
    func testDumpASampleRun() throws {
        guard let dest = ProcessInfo.processInfo.environment["AZ0X_DUMP"] else {
            throw XCTSkip("set AZ0X_DUMP to a path")
        }
        var results: [String: ItemResult] = [:]
        for item in TestItem.ddrItems {
            var r = ItemResult(code: item.code)
            r.measurements = [.num("实际历时", 43_213, "s")]
            if !item.isRecordOnly { r.criteria = [.equals("检查", 0, 0)] }
            r.conclude()
            results[item.code] = r
        }
        results["T01"]?.measurements.append(.text("匹配 cfg", "lpddr4x_2112MHz_AZ08.cfg"))
        results["T04"]?.measurements.append(.text("镜像", "image-raw-format-AZ08.img"))
        results["T05"]?.measurements = [.num("峰值带宽", 12_164, "MB/s"), .num("DDR 频率", 2112, "MHz")]
        // The case that did not exist before: a record-only reading we could not take.
        var t05 = ItemResult(code: "T05")
        t05.measurements = results["T05"]?.measurements ?? []
        t05.interrupted("固件缺少 stress-ng —— 无法加压，采样无意义")
        results["T05"] = t05
        results["T06"]?.measurements.append(contentsOf: [
            .num("完成段数", 3), .num("成功切频次数", 132), .num("memtester 循环数（变频段）", 7)])
        results["T06"]?.evidence = [.markdown("各段总览", "| 阶段 | 结论 |\n|---|---|\n| 第 1 段 | 已完成 |")]

        let run = Run(schemaVersion: Run.currentSchema, runID: "1787190336-FB1391E4",
                      batchID: "AZ08-DDR-20260824-100000", model: .az08, flow: .ddr,
                      board: .init(serial: "34376b2c031e323e", cpuid: "c0ffee0102030405",
                                   chipVariant: nil, socket: "002-1.4",
                                   reported: "Focalcrest AZ08 / RK3576", uptimeAtBind: 42),
                      burninPhases: BurninPhase.allCases, scale: .standard, items: TestItem.ddrItems,
                      results: results,
                      startedAt: Date(timeIntervalSince1970: 1_787_000_000),
                      finishedAt: Date(timeIntervalSince1970: 1_787_130_000),
                      stoppedAt: nil, abortedAt: nil,
                      toolVersions: ["RockchipDDRTestUtilityCLI 1.4.2"], appVersion: "2.0")

        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted
        try e.encode(run).write(to: URL(fileURLWithPath: dest))
    }
}
