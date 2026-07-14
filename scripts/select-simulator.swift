#!/usr/bin/env swift
import Foundation

struct Listing: Decodable { let devices: [String: [Device]] }
struct Device: Decodable {
    let state: String
    let isAvailable: Bool
    let name: String
    let udid: String
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let listing = try JSONDecoder().decode(Listing.self, from: input)
let runtimes = listing.devices.keys
    .filter { $0.contains("SimRuntime.iOS-") }
    .sorted(by: >)
for runtime in runtimes {
    let candidates = (listing.devices[runtime] ?? [])
        .filter { $0.isAvailable && $0.name.hasPrefix("iPhone") }
        .sorted {
            if $0.state != $1.state { return $0.state == "Booted" }
            return $0.name < $1.name
        }
    if let device = candidates.first {
        print(device.udid)
        exit(EXIT_SUCCESS)
    }
}
fputs("No available iPhone simulator. Install an iOS Simulator runtime in Xcode.\n", stderr)
exit(EXIT_FAILURE)
