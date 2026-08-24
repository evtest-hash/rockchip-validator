import Foundation

/// The only symbol this library exposes.
///
/// Keeping the surface to one function is what keeps the executable thin: the CLI parses arguments
/// and prints, and every decision stays inside the core where it can be tested. It also means the
/// model never has to be made `public` to be driven, so nothing about the internal shape is
/// pinned by the fact that a command-line tool exists.
public enum AZ0X {

    /// Runs one command. Returns the process exit status.
    public static func run(_ arguments: [String]) async -> Int32 {
        var args = arguments
        let command = args.isEmpty ? "help" : args.removeFirst()

        switch command {
        case "report":
            return renderReport(path: args.first)
        case "help", "-h", "--help":
            print(usage)
            return 0
        default:
            FileHandle.standardError.write(Data("未知命令：\(command)\n\n\(usage)\n".utf8))
            return 2
        }
    }

    private static let usage = """
        az0x —— AZ0X 物料验证执行台

        用法：
          az0x report <run.json>    重新渲染一次已归档的运行
          az0x help                 显示本说明
        """

    /// Re-renders an archived run. The record is the only input: no board, no network, no state.
    private static func renderReport(path: String?) -> Int32 {
        guard let path else {
            FileHandle.standardError.write(Data("report 需要一个 run.json 路径\n".utf8))
            return 2
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("读不到 \(path)\n".utf8))
            return 1
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let run = try? decoder.decode(Run.self, from: data) else {
            FileHandle.standardError.write(Data("\(path) 不是这个程序认识的运行记录\n".utf8))
            return 1
        }
        print(ReportRenderer.render(run))
        return 0
    }
}
