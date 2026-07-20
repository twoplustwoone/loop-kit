import Darwin
import Foundation
import LoopKitOffline

@main
struct LoopKitOfflineDSPCommand {
  static func main() {
    do {
      let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
      let application = try WaveFile.read(from: arguments.applicationInput)
      let microphone = try arguments.microphoneInput.map(WaveFile.read)
      let output = try OfflineMixer.process(
        application: application,
        microphone: microphone,
        options: arguments.options
      )
      try WaveFile.write(output, to: arguments.output)
      print("Processed \(output.left.count) frames at \(output.sampleRate) Hz → \(arguments.output.path)")
    } catch {
      let message = "loopkit_offline_dsp: \(error.localizedDescription)\n"
      FileHandle.standardError.write(Data(message.utf8))
      printUsage()
      exit(2)
    }
  }

  private struct Arguments {
    let applicationInput: URL
    let microphoneInput: URL?
    let output: URL
    let options: OfflineMixOptions
  }

  private static func parseArguments(_ values: [String]) throws -> Arguments {
    guard values.count >= 2 else {
      throw OfflineAudioError.invalidAudio("Input and output paths are required")
    }

    var options = OfflineMixOptions()
    var microphoneInput: URL?
    var index = 2
    while index < values.count {
      switch values[index] {
      case "--mute":
        options.application.muted = true
        index += 1
      case "--app-mute":
        options.application.muted = true
        index += 1
      case "--mic-mute":
        options.microphone.muted = true
        index += 1
      case "--app-solo":
        options.application.solo = true
        index += 1
      case "--mic-solo":
        options.microphone.solo = true
        index += 1
      case "--app-disable":
        options.application.enabled = false
        index += 1
      case "--mic-disable":
        options.microphone.enabled = false
        index += 1
      case "--mic-input":
        guard index + 1 < values.count else {
          throw OfflineAudioError.invalidAudio("--mic-input requires a WAVE path")
        }
        microphoneInput = URL(fileURLWithPath: values[index + 1])
        index += 2
      case "--gain", "--app-gain", "--mic-gain", "--master-gain":
        guard index + 1 < values.count, let gain = Double(values[index + 1]) else {
          throw OfflineAudioError.invalidAudio("\(values[index]) requires a numeric value")
        }
        switch values[index] {
        case "--gain", "--app-gain": options.application.gain = gain
        case "--mic-gain": options.microphone.gain = gain
        default:
          options.masterGain = gain
        }
        index += 2
      default:
        throw OfflineAudioError.invalidAudio("Unknown option: \(values[index])")
      }
    }

    return Arguments(
      applicationInput: URL(fileURLWithPath: values[0]),
      microphoneInput: microphoneInput,
      output: URL(fileURLWithPath: values[1]),
      options: options
    )
  }

  private static func printUsage() {
    print("""
      Usage: loopkit_offline_dsp APP.wav OUTPUT.wav [options]
        --mic-input MIC.wav       Add a microphone input (sample rates must match)
        --app-gain N              Application gain (--gain is an alias)
        --mic-gain N              Microphone gain
        --master-gain N           Master gain
        --app-mute | --mic-mute   Mute a source (--mute aliases --app-mute)
        --app-solo | --mic-solo   Solo a source
        --app-disable | --mic-disable
      """)
  }
}
