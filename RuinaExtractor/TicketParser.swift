import Foundation

/// Minimal Switch .tik parser: pulls out the rights ID and the (common-key encrypted) title key.
/// hactool decrypts the title key itself using titlekek from prod.keys.
enum TicketParser {
    struct Ticket {
        let rightsID: String   // 32 hex chars
        let titleKey: String   // 32 hex chars
    }

    enum TicketError: LocalizedError {
        case malformed
        case personalized
        var errorDescription: String? {
            switch self {
            case .malformed: return "Ticket file is malformed."
            case .personalized: return "This ticket is personalized (console-unique). It needs the console's private key to decrypt, which isn't supported. Use a dump with a common ticket or an XCI."
            }
        }
    }

    static func parse(_ data: Data) throws -> Ticket {
        func u32(_ o: Int) -> UInt32? {
            guard data.count >= o + 4 else { return nil }
            return UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
        }
        guard let sigType = u32(0) else { throw TicketError.malformed }
        let sigSize: Int, pad: Int
        switch sigType {
        case 0x10000, 0x10003: (sigSize, pad) = (0x200, 0x3C)
        case 0x10001, 0x10004: (sigSize, pad) = (0x100, 0x3C)
        case 0x10002, 0x10005: (sigSize, pad) = (0x3C, 0x40)
        default: throw TicketError.malformed
        }
        let body = 4 + sigSize + pad
        guard data.count >= body + 0x170 else { throw TicketError.malformed }
        let keyType = data[body + 0x141]          // 0 = common, 1 = personalized
        if keyType != 0 { throw TicketError.personalized }
        let key = data[(body + 0x40)..<(body + 0x50)]
        let rid = data[(body + 0x160)..<(body + 0x170)]
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        return Ticket(rightsID: hex(rid), titleKey: hex(key))
    }
}
