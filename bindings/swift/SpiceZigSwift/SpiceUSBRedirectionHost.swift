import CSpiceZig
import Foundation

public enum SpiceUSBRedirectionHostError: Error, Sendable, Equatable {
    case invalidArgument
    case allocationFailed
    case backendFailure(code: Int32)
    case bufferedOutputLimitExceeded
    case deviceNotFound
    case deviceRejectedByGuest
}

// Native Host serializes access and is reference counted. Session runners retain
// the same native object; Swift ownership may end while that native lease lives.
final class ZigUSBHostOwner: @unchecked Sendable {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { spice_zig_usb_host_destroy(raw) }
}

/// Exact usbredir backend. Devices are opened only by explicit bus/address calls.
public actor SpiceUSBRedirectionHost {
    nonisolated let owner: ZigUSBHostOwner
    public init(maximumBufferedBytes: Int = 16 * 1_024 * 1_024,
                maximumSpicePacketBytes: Int = 1 * 1_024 * 1_024) throws(SpiceUSBRedirectionHostError) {
        guard maximumBufferedBytes > 0, maximumBufferedBytes <= 64 * 1_024 * 1_024,
              maximumSpicePacketBytes > 0, maximumSpicePacketBytes <= maximumBufferedBytes else {
            throw .invalidArgument
        }
        var options = SpiceZigUSBHostOptions(maximum_buffered_bytes: maximumBufferedBytes,
                                            maximum_packet_bytes: maximumSpicePacketBytes)
        var raw: OpaquePointer?
        let status = spice_zig_usb_host_create(&options, &raw)
        try Self.check(status, native: 0)
        guard let raw else { throw .allocationFailed }
        owner = ZigUSBHostOwner(raw)
    }
    public func initialPackets() -> [Data] {
        do { return try exchange(kind: 0) }
        catch { preconditionFailure("USB initial packet allocation failed") }
    }
    public func receiveFromGuest(_ data: Data) throws(SpiceUSBRedirectionHostError) -> [Data] {
        try exchange(kind: 1, data: data)
    }
    public func attachDevice(busNumber: UInt8, deviceAddress: UInt8) throws(SpiceUSBRedirectionHostError) -> [Data] {
        try exchange(kind: 2, bus: busNumber, address: deviceAddress)
    }
    public func detachDevice() throws(SpiceUSBRedirectionHostError) -> [Data] { try exchange(kind: 3) }
    public func pumpEvents(timeoutMilliseconds: UInt32 = 0) throws(SpiceUSBRedirectionHostError) -> [Data] {
        try exchange(kind: 4, milliseconds: timeoutMilliseconds)
    }
    private nonisolated func exchange(kind: UInt8, data: Data = Data(), bus: UInt8 = 0, address: UInt8 = 0,
                          milliseconds: UInt32 = 0) throws(SpiceUSBRedirectionHostError) -> [Data] {
        var packets: OpaquePointer?
        var native: Int32 = 0
        let status = data.withUnsafeBytes {
            spice_zig_usb_host_exchange(owner.raw, kind, $0.bindMemory(to: UInt8.self).baseAddress,
                                       $0.count, bus, address, milliseconds, &packets, &native)
        }
        try Self.check(status, native: native)
        guard let packets else { throw .allocationFailed }
        defer { spice_zig_usb_packets_destroy(packets) }
        var count = 0, maximum = 0
        let bytes = spice_zig_usb_packets_bytes(packets, &count, &maximum)
        guard count > 0 else { return [] }
        precondition(maximum > 0 && bytes != nil)
        return stride(from: 0, to: count, by: maximum).map {
            Data(bytes: bytes!.advanced(by: $0), count: min(maximum, count - $0))
        }
    }
    nonisolated static func check(_ status: Int32, native: Int32) throws(SpiceUSBRedirectionHostError) {
        switch status {
        case 0: return
        case -100: throw .invalidArgument
        case -101: throw .allocationFailed
        case -103: throw .bufferedOutputLimitExceeded
        case -104: throw .deviceNotFound
        case -105: throw .deviceRejectedByGuest
        default: throw .backendFailure(code: native == 0 ? status : native)
        }
    }
}

// Route borrows the runner. All asynchronous calls retain this lease; its final
// release removes that borrow and joins native work while Runtime remains alive.
final class ZigUSBLease: @unchecked Sendable {
    let runtime: ZigRuntime
    let raw: OpaquePointer
    init(runtime: ZigRuntime, host: ZigUSBHostOwner, channel: UInt8) throws(SpiceError) {
        self.runtime = runtime
        var raw: OpaquePointer?
        let status = spice_zig_usb_create_shared(runtime.raw, channel, host.raw, &raw)
        guard status == 0, let raw else { throw .protocolError("USB backend creation (\(status))") }
        let attached = spice_zig_usb_route_attach(runtime.usbRoute, runtime.raw, raw)
        guard attached == 0 else {
            spice_zig_usb_destroy(raw)
            throw .protocolError("USB backend attachment (\(attached))")
        }
        self.raw = raw
    }
    func stop() { spice_zig_usb_stop(raw) }
    deinit {
        spice_zig_usb_route_detach(runtime.usbRoute, raw)
        spice_zig_usb_destroy(raw)
    }
}
