import Foundation

/// Where batches land when the caller does not say.
///
/// One place, shared by the command line and the interface, so a run started either way ends up
/// somewhere the other can find.
public enum ArchiveRoot {
    public static var `default`: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("Rockchip 物料验证", isDirectory: true)
    }
}
