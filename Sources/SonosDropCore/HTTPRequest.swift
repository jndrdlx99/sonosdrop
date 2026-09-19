import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]

    /// Returns nil until the full header block ("\r\n\r\n") has arrived.
    public static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let path = String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? "")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return HTTPRequest(method: method, path: path, headers: headers)
    }
}

public enum RangeResult: Equatable, Sendable {
    case full
    case partial(Range<Int>)
    case unsatisfiable
}

public enum RangeParser {
    /// Single-range subset of RFC 7233. Multi-range requests use the first range only.
    public static func parse(_ header: String?, fileSize: Int) -> RangeResult {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)
        if startStr.isEmpty {
            guard let suffix = Int(endStr), suffix > 0 else { return .full }
            return .partial(max(0, fileSize - suffix)..<fileSize)
        }
        guard let start = Int(startStr) else { return .full }
        guard start < fileSize else { return .unsatisfiable }
        let end = endStr.isEmpty ? fileSize - 1 : min(Int(endStr) ?? (fileSize - 1), fileSize - 1)
        guard end >= start else { return .unsatisfiable }
        return .partial(start..<(end + 1))
    }
}
