#!/usr/bin/env swift
import AVFoundation
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: validate-mp4.swift <path>\n", stderr)
    exit(EXIT_FAILURE)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let semaphore = DispatchSemaphore(value: 0)
var valid = false
Task {
    do {
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        valid = playable && duration.seconds > 0 && !tracks.isEmpty
    } catch {
        fputs("MP4 validation failed: \(error)\n", stderr)
    }
    semaphore.signal()
}
semaphore.wait()
exit(valid ? EXIT_SUCCESS : EXIT_FAILURE)
