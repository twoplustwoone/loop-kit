import Darwin
import Foundation
import LoopKitOffline

@main
struct LoopKitOfflineDSPCommand {
  static func main() {
    do {
      let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
      let input = try WaveFile.read(from: arguments.input)
      let output = try OfflineMixer.process(input, options: arguments.options)
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
    let input: URL
    let output: URL
    let options: OfflineMixOptions
  }

  private static func parseArguments(_ values: [String]) throws -> Arguments {
    guard values.count >= 2 else {
      throw OfflineAudioError.invalidAudio("Input and output paths are required")
    }

    var options = OfflineMixOptions()
    var index = 2
    while index < values.count {
      switch values[index] {
      case "--mute":
        options.muted = true
        index += 1
      case "--gain", "--master-gain":
        guard index + 1 < values.count, let gain = Double(values[index + 1]) else {
          throw OfflineAudioError.invalidAudio("\(values[index]) requires a numeric value")
        }
        if values[index] == "--gain" {
          options.sourceGain = gain
        } else {
          options.masterGain = gain
        }
        index += 2
      default:
        throw OfflineAudioError.invalidAudio("Unknown option: \(values[index])")
      }
    }

    return Arguments(
      input: URL(fileURLWithPath: values[0]),
      output: URL(fileURLWithPath: values[1]),
      options: options
    )
  }

  private static func printUsage() {
    print("Usage: loopkit_offline_dsp INPUT.wav OUTPUT.wav [--gain N] [--master-gain N] [--mute]")
  }
}
