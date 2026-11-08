import Foundation
import PackagePlugin

@main
struct UnicodeWidthPlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let input = context.package.directoryURL.appendingPathComponent("UnicodeData/EastAsianWidth.txt")
    let output = context.pluginWorkDirectoryURL.appendingPathComponent("UnicodeWidth.swift")
    let generator = try context.tool(named: "UnicodeWidthGenerator")
    return [
      .buildCommand(
        displayName: "Generating Unicode terminal widths",
        executable: generator.url,
        arguments: [input.path, output.path],
        inputFiles: [input],
        outputFiles: [output]
      )
    ]
  }
}
