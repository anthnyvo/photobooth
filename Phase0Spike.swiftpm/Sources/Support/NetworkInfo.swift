import Foundation

/// Device's own IPv4 address on the Wi-Fi interface (en0) — used to build a
/// URL guests can reach LocalPhotoServer at. Only meaningful when this
/// device and the guest's phone are on the same network, which requires the
/// camera to be joined to that same venue Wi-Fi (infrastructure mode)
/// rather than creating its own private AP.
public enum NetworkInfo {
    public static func wifiIPv4Address() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = pointer {
            let interface = current.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), String(cString: interface.ifa_name) == "en0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
            }
            pointer = interface.ifa_next
        }
        return address
    }
}
