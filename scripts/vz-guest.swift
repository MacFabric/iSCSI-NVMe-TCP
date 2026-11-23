// A Linux guest under Apple's Virtualization framework, its console on this
// process's stdin and stdout, for scripts/write-stall-guest.py.
//
//   vz-guest <Image> <initrd> <disk> [image|block] [automatic|cached|uncached] [full|fsync|none]
//
// <Image> is an uncompressed arm64 kernel. `image` attaches <disk> as a disk
// image file (VZDiskImageStorageDeviceAttachment, with the caching and
// synchronization modes given); `block` opens it as a device node
// (VZDiskBlockDeviceStorageDeviceAttachment, /dev/rdiskN). Build:
//   swiftc -O -o vz-guest scripts/vz-guest.swift
//   codesign -s - -f --entitlements <plist with com.apple.security.virtualization> vz-guest
import Foundation
import Virtualization

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: vz-guest <Image> <initrd> <disk> [image|block] [automatic|cached|uncached] [full|fsync|none]\n".data(using: .utf8)!)
    exit(64)
}
let kind = args.count > 4 ? args[4] : "image"
let caching: VZDiskImageCachingMode = switch args.count > 5 ? args[5] : "automatic" {
    case "cached": .cached
    case "uncached": .uncached
    default: .automatic
}
let syncImage: VZDiskImageSynchronizationMode = switch args.count > 6 ? args[6] : "full" {
    case "fsync": .fsync
    case "none": .none
    default: .full
}
let syncBlock: VZDiskSynchronizationMode = (args.count > 6 && args[6] == "none") ? .none : .full

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("vz-guest: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: args[1]))
boot.initialRamdiskURL = URL(fileURLWithPath: args[2])
boot.commandLine = "console=hvc0 rdinit=/bin/sh quiet"

let config = VZVirtualMachineConfiguration()
config.bootLoader = boot
config.platform = VZGenericPlatformConfiguration()
config.cpuCount = 2
config.memorySize = 512 << 20
let console = VZVirtioConsoleDeviceSerialPortConfiguration()
console.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: .standardInput, fileHandleForWriting: .standardOutput)
config.serialPorts = [console]
do {
    let attachment: VZStorageDeviceAttachment
    if kind == "block" {
        guard let handle = FileHandle(forUpdatingAtPath: args[3]) else { fail("cannot open \(args[3])") }
        attachment = try VZDiskBlockDeviceStorageDeviceAttachment(
            fileHandle: handle, readOnly: false, synchronizationMode: syncBlock)
    } else {
        attachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: args[3]), readOnly: false,
            cachingMode: caching, synchronizationMode: syncImage)
    }
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
    try config.validate()
} catch {
    fail("configuration: \(error)")
}

final class Watcher: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { exit(0) }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { fail("stopped: \(error)") }
}
let watcher = Watcher()
let vm = VZVirtualMachine(configuration: config)
vm.delegate = watcher
vm.start { result in
    if case .failure(let error) = result { fail("start: \(error)") }
}
dispatchMain()
