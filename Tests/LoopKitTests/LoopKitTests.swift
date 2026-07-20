import Foundation
import XCTest
import LoopKitEngine
import LoopKitIPC
import LoopKitOffline
@testable import LoopKitDaemonCore

final class LoopKitTests: XCTestCase {

    func testEngineGainAndMixing() {
        var config = lk_engine_config(sample_rate: 48000, max_block_frames: 128)
        guard let engine = lk_engine_create(&config) else {
            XCTFail("Failed to create engine")
            return
        }
        defer { lk_engine_destroy(engine) }

        let appParams = lk_source_params(gain: 0.5, mute: 0, solo: 0, enabled: 1)
        let micParams = lk_source_params(gain: 1.0, mute: 0, solo: 0, enabled: 1)

        lk_engine_set_source_params(engine, UInt32(LK_SOURCE_APP), appParams)
        lk_engine_set_source_params(engine, UInt32(LK_SOURCE_MIC), micParams)
        lk_engine_set_master_gain(engine, 1.0)

        let appL: [Float] = [0.4, -0.2, 0.6, 0.0]
        let appR: [Float] = [0.1, -0.1, 0.3, 0.0]
        let micL: [Float] = [0.1, 0.1, -0.2, 0.0]
        let micR: [Float] = [0.1, 0.1, -0.2, 0.0]

        var outL = [Float](repeating: 0.0, count: 4)
        var outR = [Float](repeating: 0.0, count: 4)

        appL.withUnsafeBufferPointer { appLBuf in
            appR.withUnsafeBufferPointer { appRBuf in
                micL.withUnsafeBufferPointer { micLBuf in
                    micR.withUnsafeBufferPointer { micRBuf in
                        outL.withUnsafeMutableBufferPointer { outLBuf in
                            outR.withUnsafeMutableBufferPointer { outRBuf in
                                var appIn = lk_input_audio_block(left: appLBuf.baseAddress, right: appRBuf.baseAddress, frames: 4)
                                var micIn = lk_input_audio_block(left: micLBuf.baseAddress, right: micRBuf.baseAddress, frames: 4)
                                var broadcastOut = lk_output_audio_block(left: outLBuf.baseAddress, right: outRBuf.baseAddress, frames: 4)
                                var monitorOut = lk_output_audio_block(left: nil, right: nil, frames: 0)
                                var meters = lk_meter_block(peak_l: 0, peak_r: 0, rms_l: 0, rms_r: 0, clipped_l: 0, clipped_r: 0)

                                lk_engine_process(engine, &appIn, &micIn, &broadcastOut, &monitorOut, &meters)

                                XCTAssertEqual(outLBuf[0], 0.3, accuracy: 1e-4)
                                XCTAssertEqual(outLBuf[1], 0.0, accuracy: 1e-4)
                                XCTAssertEqual(outLBuf[2], 0.1, accuracy: 1e-4)
                                XCTAssertEqual(outRBuf[0], 0.15, accuracy: 1e-4)
                                XCTAssertEqual(outRBuf[1], 0.05, accuracy: 1e-4)
                                XCTAssertEqual(outRBuf[2], -0.05, accuracy: 1e-4)
                                XCTAssertGreaterThanOrEqual(meters.peak_l, 0.3)
                            }
                        }
                    }
                }
            }
        }
    }

    func testEngineMuteAndSolo() {
        var config = lk_engine_config(sample_rate: 48000, max_block_frames: 128)
        guard let engine = lk_engine_create(&config) else {
            XCTFail("Failed to create engine")
            return
        }
        defer { lk_engine_destroy(engine) }

        var appParams = lk_source_params(gain: 1.0, mute: 0, solo: 1, enabled: 1)
        let micParams = lk_source_params(gain: 1.0, mute: 0, solo: 0, enabled: 1)

        lk_engine_set_source_params(engine, UInt32(LK_SOURCE_APP), appParams)
        lk_engine_set_source_params(engine, UInt32(LK_SOURCE_MIC), micParams)

        let appL: [Float] = [0.5]
        let appR: [Float] = [0.5]
        let micL: [Float] = [0.5]
        let micR: [Float] = [0.5]
        var outL = [Float](repeating: 0.0, count: 1)
        var outR = [Float](repeating: 0.0, count: 1)

        appL.withUnsafeBufferPointer { appLBuf in
            appR.withUnsafeBufferPointer { appRBuf in
                micL.withUnsafeBufferPointer { micLBuf in
                    micR.withUnsafeBufferPointer { micRBuf in
                        outL.withUnsafeMutableBufferPointer { outLBuf in
                            outR.withUnsafeMutableBufferPointer { outRBuf in
                                var appIn = lk_input_audio_block(left: appLBuf.baseAddress, right: appRBuf.baseAddress, frames: 1)
                                var micIn = lk_input_audio_block(left: micLBuf.baseAddress, right: micRBuf.baseAddress, frames: 1)
                                var broadcastOut = lk_output_audio_block(left: outLBuf.baseAddress, right: outRBuf.baseAddress, frames: 1)
                                var monitorOut = lk_output_audio_block(left: nil, right: nil, frames: 0)
                                var meters = lk_meter_block(peak_l: 0, peak_r: 0, rms_l: 0, rms_r: 0, clipped_l: 0, clipped_r: 0)

                                lk_engine_process(engine, &appIn, &micIn, &broadcastOut, &monitorOut, &meters)
                                XCTAssertEqual(outLBuf[0], 0.5, accuracy: 1e-4, "Solo APP should exclude non-solo MIC")

                                // Now mute APP and solo neither
                                appParams.solo = 0
                                appParams.mute = 1
                                lk_engine_set_source_params(engine, UInt32(LK_SOURCE_APP), appParams)

                                lk_engine_process(engine, &appIn, &micIn, &broadcastOut, &monitorOut, &meters)
                                XCTAssertEqual(outLBuf[0], 0.5, accuracy: 1e-4, "Muted APP should be ignored, leaving only MIC (0.5)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testEngineLimiterAndMeters() {
        var config = lk_engine_config(sample_rate: 48000, max_block_frames: 128)
        guard let engine = lk_engine_create(&config) else {
            XCTFail("Failed to create engine")
            return
        }
        defer { lk_engine_destroy(engine) }

        lk_engine_set_master_gain(engine, 4.0)

        let appL: [Float] = [1.0, -1.0]
        let appR: [Float] = [1.0, -1.0]
        let zeros: [Float] = [0.0, 0.0]
        var outL = [Float](repeating: 0.0, count: 2)
        var outR = [Float](repeating: 0.0, count: 2)

        appL.withUnsafeBufferPointer { appLBuf in
            appR.withUnsafeBufferPointer { appRBuf in
                zeros.withUnsafeBufferPointer { zerosBuf in
                    outL.withUnsafeMutableBufferPointer { outLBuf in
                        outR.withUnsafeMutableBufferPointer { outRBuf in
                            var appIn = lk_input_audio_block(left: appLBuf.baseAddress, right: appRBuf.baseAddress, frames: 2)
                            var micIn = lk_input_audio_block(left: zerosBuf.baseAddress, right: zerosBuf.baseAddress, frames: 2)
                            var broadcastOut = lk_output_audio_block(left: outLBuf.baseAddress, right: outRBuf.baseAddress, frames: 2)
                            var monitorOut = lk_output_audio_block(left: nil, right: nil, frames: 0)
                            var meters = lk_meter_block(peak_l: 0, peak_r: 0, rms_l: 0, rms_r: 0, clipped_l: 0, clipped_r: 0)

                            lk_engine_process(engine, &appIn, &micIn, &broadcastOut, &monitorOut, &meters)

                            XCTAssertLessThanOrEqual(abs(outLBuf[0]), 1.0, "soft clipping upper bound")
                            XCTAssertLessThanOrEqual(abs(outLBuf[1]), 1.0, "soft clipping lower bound")
                            XCTAssertLessThanOrEqual(meters.peak_l, 1.0, "peak meter bound")
                            XCTAssertGreaterThan(meters.rms_l, 0.0, "rms meter non-zero")
                        }
                    }
                }
            }
        }
    }

    func testSceneStoreJSONRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = SceneStore(folder: folder)
        let source = LKXPCSourceState(
            id: "app:com.example.player",
            displayName: "Player",
            gain: 0.625,
            mute: true,
            solo: false,
            enabled: true
        )
        let scene = LKXPCScene(
            name: "Streaming",
            masterGain: 0.8,
            monitorDeviceUID: "monitor.uid",
            sources: [source],
            routes: [
                LKXPCRoute(sourceID: source.id, destinationID: LKRouteDestinationBroadcast)
            ]
        )

        try store.write(
            scene,
            capturedAppBundleIDs: ["com.example.player"],
            captureModePreference: "processTapPreferred",
            playbackPolicy: "redirectMuted"
        )
        let loaded = try store.read(named: scene.name)

        XCTAssertEqual(store.listNames(), ["Streaming"])
        XCTAssertEqual(loaded.scene.name, scene.name)
        XCTAssertEqual(loaded.scene.masterGain, scene.masterGain)
        XCTAssertEqual(loaded.scene.monitorDeviceUID, scene.monitorDeviceUID)
        XCTAssertEqual(loaded.scene.sources.count, 1)
        XCTAssertEqual(loaded.scene.sources[0].id, source.id)
        XCTAssertEqual(loaded.scene.sources[0].displayName, source.displayName)
        XCTAssertEqual(loaded.scene.sources[0].gain, source.gain)
        XCTAssertEqual(loaded.scene.sources[0].mute, source.mute)
        XCTAssertEqual(loaded.scene.sources[0].solo, source.solo)
        XCTAssertEqual(loaded.scene.sources[0].enabled, source.enabled)
        XCTAssertEqual(loaded.scene.routes?.count, 1)
        XCTAssertEqual(loaded.scene.routes?.first?.sourceID, source.id)
        XCTAssertEqual(loaded.scene.routes?.first?.destinationID, LKRouteDestinationBroadcast)
        XCTAssertEqual(loaded.capturedAppBundleIDs, ["com.example.player"])
        XCTAssertEqual(loaded.captureModePreference, "processTapPreferred")
        XCTAssertEqual(loaded.playbackPolicy, "redirectMuted")
    }

    func testSceneStoreLoadsLegacyJSONWithoutOptionalRoutingFields() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let legacyJSON = """
        {
          "name": "Legacy",
          "masterGain": 1.0,
          "monitorDeviceUID": "system.default",
          "sources": []
        }
        """
        try Data(legacyJSON.utf8).write(to: folder.appendingPathComponent("Legacy.json"))

        let loaded = try SceneStore(folder: folder).read(named: "Legacy")
        XCTAssertEqual(loaded.scene.name, "Legacy")
        XCTAssertEqual(loaded.capturedAppBundleIDs, [])
        XCTAssertNil(loaded.captureModePreference)
        XCTAssertNil(loaded.playbackPolicy)
        XCTAssertNil(loaded.scene.routes)
    }

    func testRouteTableDefaultsNewSourcesAndReplacesAtomically() throws {
        var table = RouteTable()
        table.reconcile(sourceIDs: ["mic", "app:player"])

        XCTAssertTrue(table.contains(sourceID: "mic", destinationID: LKRouteDestinationMonitor))
        XCTAssertTrue(table.contains(sourceID: "mic", destinationID: LKRouteDestinationBroadcast))
        XCTAssertEqual(table.xpcRoutes().count, 4)

        try table.replace(with: [
            LKXPCRoute(sourceID: "app:player", destinationID: LKRouteDestinationBroadcast)
        ])
        XCTAssertEqual(table.xpcRoutes().count, 1)
        XCTAssertFalse(table.contains(sourceID: "mic", destinationID: LKRouteDestinationMonitor))

        XCTAssertThrowsError(try table.replace(with: [
            LKXPCRoute(sourceID: "unknown", destinationID: LKRouteDestinationMonitor)
        ]))
        XCTAssertEqual(table.xpcRoutes().count, 1, "a rejected replacement must not partially mutate the graph")
    }

    func testRouteTableLegacyRestoreDefaultsButExplicitEmptyDisconnects() {
        var table = RouteTable()
        table.restore(nil, sourceIDs: ["mic"])
        XCTAssertEqual(table.xpcRoutes().count, 2)

        table.restore([], sourceIDs: ["mic"])
        XCTAssertTrue(table.xpcRoutes().isEmpty)
    }

    func testGainPolicyClampsInvalidBoundaryValues() {
        XCTAssertEqual(ControlPolicy.gain(-2), 0)
        XCTAssertEqual(ControlPolicy.gain(12), 8)
        XCTAssertEqual(ControlPolicy.gain(.nan), 1)
        XCTAssertEqual(ControlPolicy.gain(0.625), 0.625)
    }

    func testMonitorPolicyFallsBackWhenPreferredDeviceDisappears() {
        let devices = [MonitorOutputDevice(uid: "speaker", name: "MacBook Speakers")]
        var attempts: [String] = []

        let decision = MonitorOutputPolicy.activate(
            requestedUID: "usb-headset",
            devices: devices,
            defaultUID: "speaker",
            allowFallback: true
        ) { uid in
            attempts.append(uid)
            return uid == "speaker" ? nil : "Device unavailable"
        }

        XCTAssertEqual(attempts, ["usb-headset", "speaker"])
        XCTAssertTrue(decision.succeeded)
        XCTAssertEqual(decision.activeUID, "speaker")
        XCTAssertTrue(decision.fallbackActive)
        XCTAssertTrue(decision.warning?.contains("MacBook Speakers") == true)
    }

    func testMonitorPolicyDoesNotFallbackWhenDisabled() {
        var attempts: [String] = []
        let decision = MonitorOutputPolicy.activate(
            requestedUID: "usb-headset",
            devices: [MonitorOutputDevice(uid: "speaker", name: "MacBook Speakers")],
            defaultUID: "speaker",
            allowFallback: false
        ) { uid in
            attempts.append(uid)
            return "Device unavailable"
        }

        XCTAssertEqual(attempts, ["usb-headset"])
        XCTAssertFalse(decision.succeeded)
        XCTAssertFalse(decision.fallbackActive)
        XCTAssertEqual(decision.warning, "Device unavailable")
    }

    func testAudioProcessingSchedulePrimesAndTracksTime() {
        var schedule = AudioProcessingSchedule(
            sampleRate: 48_000,
            blockFrames: 512,
            leadFrames: 1_536,
            maxCatchUpBlocks: 4
        )

        XCTAssertEqual(
            schedule.advance(nowNanos: 1_000_000_000),
            AudioScheduleDecision(blockCount: 3, discontinuity: false)
        )
        XCTAssertEqual(
            schedule.advance(nowNanos: 1_005_333_333),
            AudioScheduleDecision(blockCount: 0, discontinuity: false)
        )
        XCTAssertEqual(
            schedule.advance(nowNanos: 1_011_000_000),
            AudioScheduleDecision(blockCount: 1, discontinuity: false)
        )
    }

    func testAudioProcessingScheduleBoundsCatchUp() {
        var schedule = AudioProcessingSchedule(
            sampleRate: 48_000,
            blockFrames: 512,
            leadFrames: 1_536,
            maxCatchUpBlocks: 4
        )
        _ = schedule.advance(nowNanos: 1_000_000_000)

        XCTAssertEqual(
            schedule.advance(nowNanos: 2_000_000_000),
            AudioScheduleDecision(blockCount: 4, discontinuity: true)
        )
        XCTAssertEqual(schedule.discontinuities, 1)
        XCTAssertEqual(
            schedule.advance(nowNanos: 2_000_000_000),
            AudioScheduleDecision(blockCount: 0, discontinuity: false)
        )
    }

    func testOfflineWaveRoundTripAndMixer() throws {
        let input = try StereoAudio(
            sampleRate: 48_000,
            left: [0.2, -0.2, 0.1, -0.1],
            right: [0.1, -0.1, 0.05, -0.05]
        )
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopKitOfflineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let waveURL = folder.appendingPathComponent("input.wav")

        try WaveFile.write(input, to: waveURL)
        let decoded = try WaveFile.read(from: waveURL)
        XCTAssertEqual(decoded, input)

        let mixed = try OfflineMixer.process(
            decoded,
            options: OfflineMixOptions(sourceGain: 0.5, masterGain: 1, muted: false)
        )
        XCTAssertEqual(mixed.left[0], 0.1, accuracy: 1e-4)
        XCTAssertEqual(mixed.right[0], 0.05, accuracy: 1e-4)

        let muted = try OfflineMixer.process(decoded, options: OfflineMixOptions(muted: true))
        XCTAssertTrue(muted.left.allSatisfy { $0 == 0 })
        XCTAssertTrue(muted.right.allSatisfy { $0 == 0 })
    }

    func testIPCSecureCodingRoundTripsSourceAndStatus() throws {
        let source = LKXPCSourceState(
            id: "app:com.example.player",
            displayName: "Player",
            gain: 0.75,
            mute: true,
            solo: false,
            enabled: true
        )
        let sourceData = try NSKeyedArchiver.archivedData(
            withRootObject: source,
            requiringSecureCoding: true
        )
        let decodedSource = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: LKXPCSourceState.self, from: sourceData)
        )
        XCTAssertEqual(decodedSource.id, source.id)
        XCTAssertEqual(decodedSource.displayName, source.displayName)
        XCTAssertEqual(decodedSource.gain, source.gain)
        XCTAssertEqual(decodedSource.mute, source.mute)

        let status = LKXPCStatus(
            daemonOnline: true,
            sampleRate: 48_000,
            blockFrames: 512,
            captureMode: LKCaptureModeUnavailable,
            captureWarning: "No capture adapter"
        )
        let statusData = try NSKeyedArchiver.archivedData(
            withRootObject: status,
            requiringSecureCoding: true
        )
        let decodedStatus = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: LKXPCStatus.self, from: statusData)
        )
        XCTAssertTrue(decodedStatus.daemonOnline)
        XCTAssertEqual(decodedStatus.sampleRate, 48_000)
        XCTAssertEqual(decodedStatus.captureMode, LKCaptureModeUnavailable)
        XCTAssertEqual(decodedStatus.captureWarning, "No capture adapter")

        let meter = LKXPCMeter(
            sourceID: LKMeterSourceBroadcastMix,
            peakL: 0.99,
            peakR: 0.8,
            rmsL: 0.5,
            rmsR: 0.4,
            clippedL: true,
            clippedR: false
        )
        let meterData = try NSKeyedArchiver.archivedData(
            withRootObject: meter,
            requiringSecureCoding: true
        )
        let decodedMeter = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: LKXPCMeter.self, from: meterData)
        )
        XCTAssertTrue(decodedMeter.clippedL)
        XCTAssertFalse(decodedMeter.clippedR)
    }
}
