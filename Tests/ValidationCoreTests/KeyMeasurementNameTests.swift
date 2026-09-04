import XCTest
@testable import ValidationCore

/// The names the report looks for beside an item's verdict must be names an item actually records.
///
/// When they drift, nothing breaks: the lookup finds no match, falls back to "the first few
/// measurements", and the column quietly shows something else. It happened for real when the tool's
/// v2.7 dropped two of T02's readings — found by reading a report, not by a test.
///
/// The names are collected by **running both flows** against declared boards, not by scanning the
/// sources for string literals. The scanner version reported ten eMMC names as missing while the
/// items were recording them all along: those come from tables of cases that a loop turns into
/// measurements, and every table has a different shape. Asking the producer is the only way that
/// does not need maintaining.
final class KeyMeasurementNameTests: XCTestCase {

    private func tool() -> ScriptedMaskromTool {
        ScriptedMaskromTool([
            "--detect": .init(json: ["detect": ["pass": true, "type": "LPDDR4X", "capacityMB": 8192,
                                                "channels": 4, "csPerDie": 1,
                                                "tier": "uniqueByCoarse", "cfg": "lpddr4x.cfg",
                                                "geometry": ["busWidthBits": 16, "dieWidthBits": 16]],
                                     "cpuid": "c0ffee01", "serial": "34376b2c031e323e"], exitCode: 0),
            "--solder": .init(json: ["solder": ["pass": true, "cfg": "lpddr4x.cfg",
                                                "log": "Size=8192MB BW=64"]], exitCode: 0),
            "--eyescan": .init(json: ["eyescan": ["pass": true, "completed": true, "bytes": 40_960,
                                                  "transcript": "all result: pass"],
                                      "elapsedMs": 800_000], exitCode: 0),
        ])
    }

    /// Every measurement name the two flows record on a healthy board.
    private func recordedNames() async -> Set<String> {
        var names: Set<String> = []
        for (flow, items, board) in [
            (ValidationFlow.ddr, TestItem.ddrItems, ScriptedBench.board()),
            (ValidationFlow.emmc, TestItem.emmcItems, ScriptedEmmc.board()),
        ] {
            var p = RunPlan(batchID: "AZ08-\(flow)", model: .az08, flow: flow, items: items,
                            burninPhases: Set(BurninPhase.allCases),
                            deviceID: "002-1.4-2207-350e-NA")
            p.burninSeconds = 43_200
            p.cycles = 3_000
            p.image = readyImage
            let v = Validator(plan: p, tool: tool(), boardSession: { _ in board },
                              flashTool: ScriptedFlasher(), clock: SimClock())
            let run = await v.run { _ in }
            for result in run.results.values {
                names.formUnion(result.measurements.map(\.name))
            }
        }
        return names
    }

    func testEveryKeyNameIsOneAProducerRecords() async {
        let recorded = await recordedNames()
        XCTAssertFalse(recorded.isEmpty, "一个名字都没收集到，这条测试就没在检查任何东西")

        for (code, names) in ReportRenderer.keyMeasurementNames.sorted(by: { $0.key < $1.key }) {
            for name in names {
                XCTAssertTrue(recorded.contains(name),
                              "\(code) 的报告要找「\(name)」，但健康板跑完一轮没有记录这个名字"
                            + " —— 结果列会静默走兜底，列出别的东西")
            }
        }
    }

    /// Every item that can be judged has an entry, so no row falls back by omission.
    func testEveryJudgedItemHasKeyNames() {
        for item in TestItem.ddrItems + TestItem.emmcItems where !item.isLongRunning {
            XCTAssertNotNil(ReportRenderer.keyMeasurementNames[item.code],
                            "\(item.code) 没有关键实测值，报告那一列只能兜底")
        }
    }
}
