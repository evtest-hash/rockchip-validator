import Foundation

/// A capability a model may lack.
public enum Capability: String, Codable {
    /// DQ eye scan (T03).
    case eyescan
}

/// Execution domain.
public enum ExecutionDomain: String, Codable {
    /// maskrom, reached over direct USB with VID 0x2207: T01 to T04 and E01.
    case maskrom
    /// On-board Linux over adb, booted from the flashed image with root: T05 to T08, E02 to E06.
    case board
}

/// The static definition of a test item: what it measures, how it is judged, and where it runs.
public struct TestItem: Identifiable, Codable {
    public let code: String
    public let title: String
    /// Text of the "test method" column of the report.
    public let method: String
    public let domain: ExecutionDomain
    /// Whether this is a long run, on the order of 12 hours, structured as start, poll and settle.
    public let isLongRunning: Bool
    /// Whether the item only records measurements and leaves the verdict to a human.
    public let isRecordOnly: Bool
    /// Whether the operator may deselect the item on the launcher screen.
    public let isOptional: Bool

    /// Whether the items after this one need it to have produced a result.
    ///
    /// Only flashing does: without firmware there is no booted Linux for a board item to run in.
    /// Everything else gates nothing, which is the whole point of deciding flow separately from the
    /// verdict — a record-only reading that could not be taken must not cost the operator a burn-in.
    public var gatesRest: Bool { TestItem.flashCodes.contains(code) }

    /// Capability this item requires of the model; nil means every model has it.
    public var requires: Capability?

    /// The item that implies this one: if that item is in the sequence, so is this one.
    public var impliedBy: String?

    public var id: String { code }

    /// Full title shown in the interface, for example "T02 焊接检测".
    public var displayTitle: String { "\(code) \(title)" }
}

public extension TestItem {
    /// DDR validation flow T01 to T08.
    static let ddrItems: [TestItem] = [
        TestItem(code: "T01", title: "规格验证",
                 method: "探测 DDR 实际规格并匹配配置，供人工与物料核对",
                 domain: .maskrom, isLongRunning: false, isRecordOnly: true, isOptional: false),
        TestItem(code: "T02", title: "焊接检测",
                 method: "检测 DQS/DQ/DM/CA/CS/ZQ 各信号焊接质量",
                 domain: .maskrom, isLongRunning: false, isRecordOnly: false, isOptional: false),
        TestItem(code: "T03", title: "DQ 眼图",
                 method: "扫描各 DQ 眼图，评估信号裕量",
                 domain: .maskrom, isLongRunning: false, isRecordOnly: false, isOptional: false,
                 requires: .eyescan),
        // Optional in itself, but locked as soon as an on-board item is selected; see isLocked.
        TestItem(code: "T04", title: "刷机",
                 method: "取最新生产镜像刷入，验证烧录通路",
                 domain: .maskrom, isLongRunning: false, isRecordOnly: false, isOptional: true),
        TestItem(code: "T05", title: "DDR 带宽",
                 method: "锁定最高频率并满载加压，采样实测带宽峰值",
                 domain: .board, isLongRunning: false, isRecordOnly: true, isOptional: true),
        TestItem(code: "T06", title: "拷机（定频+变频）",
                 method: "锁定最高频率与变频段长时间压力测试，检测位错与切频稳定性",
                 domain: .board, isLongRunning: true, isRecordOnly: false, isOptional: true),
        TestItem(code: "T07", title: "休眠唤醒",
                 method: "反复挂起与唤醒，检验低功耗进出稳定性",
                 domain: .board, isLongRunning: true, isRecordOnly: false, isOptional: true),
        TestItem(code: "T08", title: "重启",
                 method: "反复重启，检验每次 DDR 初始化稳定性",
                 domain: .board, isLongRunning: true, isRecordOnly: false, isOptional: true),
    ]

    /// eMMC validation flow E01 to E06.
    static let emmcItems: [TestItem] = [
        TestItem(code: "E01", title: "刷机",
                 method: "取最新生产镜像刷入 eMMC，验证写入通路",
                 domain: .maskrom, isLongRunning: false, isRecordOnly: false, isOptional: false),
        TestItem(code: "E02", title: "规格识别 + 健康状态",
                 method: "读取器件身份、健康状态与总线协商结果",
                 domain: .board, isLongRunning: false, isRecordOnly: false, isOptional: true),
        TestItem(code: "E03", title: "读写性能",
                 method: "顺序与随机读写性能测试",
                 domain: .board, isLongRunning: false, isRecordOnly: true, isOptional: true),
        TestItem(code: "E04", title: "数据完整性",
                 method: "写入后回读校验，检测数据完整性",
                 domain: .board, isLongRunning: false, isRecordOnly: false, isOptional: true),
        TestItem(code: "E05", title: "拷机",
                 method: "按目标写入量反复读写并回读校验，检测数据损坏",
                 domain: .board, isLongRunning: true, isRecordOnly: false, isOptional: true),
        // Repeats E03 with identical fio parameters.
        TestItem(code: "E06", title: "拷机后读写性能",
                 method: "拷机后以与 E03 相同的参数复测读写性能，与拷机前对比",
                 domain: .board, isLongRunning: false, isRecordOnly: true, isOptional: true,
                 impliedBy: "E05"),
    ]

    /// The items that actually exist for a model in a flow.
    static func items(for flow: ValidationFlow, model: BoardModel) -> [TestItem] {
        all(for: flow).filter { supports($0, model: model) }
    }

    /// The complete item table of a flow, independent of model.
    static func all(for flow: ValidationFlow) -> [TestItem] {
        flow == .ddr ? ddrItems : emmcItems
    }

    static func supports(_ item: TestItem, model: BoardModel) -> Bool {
        guard let need = item.requires else { return true }
        return model.supports(need)
    }

    /// Items excluded for this model, used by the report to generate the sequence-scope note.
    static func excluded(for flow: ValidationFlow, model: BoardModel) -> [TestItem] {
        all(for: flow).filter { !supports($0, model: model) }
    }

    // MARK: - Partial runs

    /// Whether the item cannot be deselected under the given selection.
    ///
    /// Flashing locks as soon as an on-board item is selected: those items run on the firmware this
    /// project builds, and flashing is what makes the addressing premise hold.
    static func isLocked(_ item: TestItem, picked: Set<String>,
                         flow: ValidationFlow, model: BoardModel) -> Bool {
        if !item.isOptional { return true }
        guard flashCodes.contains(item.code) else { return false }
        return items(for: flow, model: model).contains {
            $0.domain == .board && (!$0.isOptional || picked.contains($0.code))
        }
    }

    /// The sequence to execute: locked items plus the selected ones, in flow order.
    static func resolveSelection(_ picked: Set<String>,
                                 flow: ValidationFlow,
                                 model: BoardModel) -> [TestItem] {
        let available = items(for: flow, model: model)
        return available.filter { item in
            // An implied item follows the selection state of the item that implies it.
            let deciding = item.impliedBy
                .flatMap { by in available.first { $0.code == by } } ?? item
            return isLocked(deciding, picked: picked, flow: flow, model: model)
                || picked.contains(deciding.code)
        }
    }

    /// Items the operator may select for this flow and model.
    static func optionalItems(for flow: ValidationFlow, model: BoardModel) -> [TestItem] {
        items(for: flow, model: model).filter { $0.isOptional && $0.impliedBy == nil }
    }


    static func hoursText(_ seconds: Int) -> String { durationText(seconds) }

    /// A duration as the operator set it. Sub-hour amounts read in minutes: since the screen offers
    /// 30 分钟 and 1 分钟, rendering those as 0.5 小时 and 0.0 小时 would lose the number entirely.
    static func durationText(_ seconds: Int) -> String {
        if seconds < 3600 {
            let m = Double(seconds) / 60
            return m == m.rounded() ? "\(Int(m)) 分钟" : String(format: "%.1f 分钟", m)
        }
        let h = Double(seconds) / 3600
        return h == h.rounded() ? "\(Int(h)) 小时"
                                : String(format: "%.1f 小时", h)
    }

    /// Flashing item codes of the two flows, used by the sequencer's consistency check.
    static let flashCodes: Set<String> = ["T04", "E01"]
}
