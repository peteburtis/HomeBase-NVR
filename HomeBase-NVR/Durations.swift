import Foundation

enum IntervalText {
    static func seconds(_ text: String) throws -> Int64 {
        let units: [UInt8: Int64] = [115: 1, 109: 60, 104: 3600, 100: 86400,
                                    119: 604800, 77: 2678400, 121: 31536000]
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { throw invalid() }
        var index = 0, total: Int64 = 0
        while index < bytes.count {
            while index < bytes.count, bytes[index] == 32 { index += 1 }
            if index == bytes.count { break }
            let start = index
            var number: Int64 = 0
            while index < bytes.count, (48...57).contains(bytes[index]) {
                let (product, overflow) = number.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = product.addingReportingOverflow(Int64(bytes[index] - 48))
                guard !overflow, !overflow2 else { throw invalid() }
                number = sum; index += 1
            }
            guard index > start, index < bytes.count, let unit = units[bytes[index]] else { throw invalid() }
            index += 1
            let (component, overflow) = number.multipliedReportingOverflow(by: unit)
            let (sum, overflow2) = total.addingReportingOverflow(component)
            guard !overflow, !overflow2 else { throw invalid() }
            total = sum
        }
        guard total > 0 else { throw invalid() }
        return total
    }
    private static func invalid() -> ServiceError {
        ServiceError(.invalidMessage, "Use a positive duration such as 1m, 1h30m, or 1w2d. Units: s/m/h/d/w/M/y; M is 31 days, y is 365 days.")
    }
}
