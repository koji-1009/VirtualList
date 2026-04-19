#!/usr/bin/env swift
//
// extract_gate_results.swift — reads VirtualListPerformanceGates results
// from an xcresult bundle via `xcrun xcresulttool` and emits a compact
// Markdown table on stdout, a JSON summary on stderr. Uses
// `xcresulttool get test-results tests` (Xcode 15+).
//
// Usage:
//   swift .github/scripts/extract_gate_results.swift <TestResults.xcresult>
//
// Replaces the earlier Python implementation so the CI tool-chain stays
// pure-Swift.
//

import Foundation

let gateBudgets: [(name: String, budget: String)] = [
  ("test_gate_indexedApplyIsConstantTime", "< 10 ms (wall clock, n=1M)"),
  ("test_gate_indexedApplyIsConstantMemory", "< 2 MB RSS Δ (n=1M)"),
  ("test_gate_redundantApplyIsDeduped", "< 1 ms (n=100k, dedup)"),
  ("test_gate_indexPathLookupDoesNotCopySnapshot", "< 1 ms (n=100k)"),
  ("test_gate_cellBuildsAreBoundedByVisibleWindow", "< 50 cell builds"),
  ("test_gate_repeatedTeardownDoesNotLeak", "< 8 MB RSS Δ (50 cycles)"),
  ("test_gate_sequentialAppliesDoNotDegrade", "< 2 s (100 sequential applies)"),
]

func writeHeader() {
  print("| gate | budget | result | duration |")
  print("|------|--------|--------|---------:|")
}

func emitFallback(_ message: String) {
  writeHeader()
  print("| _\(message)_ | – | – | – |")
  exit(0)
}

guard CommandLine.arguments.count >= 2 else {
  FileHandle.standardError.write(
    Data("usage: extract_gate_results.swift <TestResults.xcresult>\n".utf8)
  )
  exit(2)
}
let bundlePath = CommandLine.arguments[1]

writeHeader()

guard FileManager.default.fileExists(atPath: bundlePath) else {
  print("| _no xcresult bundle_ | – | – | – |")
  exit(0)
}

// Shell out to xcresulttool. Failure is non-fatal — the workflow step
// that calls us is tagged `if: always()` and must produce a readable
// summary even when the underlying test job crashed.
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
proc.arguments = [
  "xcresulttool", "get", "test-results", "tests",
  "--path", bundlePath,
  "--format", "json",
]
let stdout = Pipe()
let stderr = Pipe()
proc.standardOutput = stdout
proc.standardError = stderr
do {
  try proc.run()
} catch {
  print("| _xcresulttool failed to launch: \(error.localizedDescription)_ | – | – | – |")
  exit(0)
}
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
  let err = String(
    data: stderr.fileHandleForReading.readDataToEndOfFile(),
    encoding: .utf8
  )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  print("| _xcresulttool failed: \(err)_ | – | – | – |")
  exit(0)
}

let data = stdout.fileHandleForReading.readDataToEndOfFile()
guard let root = try? JSONSerialization.jsonObject(with: data) else {
  print("| _could not parse xcresulttool JSON_ | – | – | – |")
  exit(0)
}

/// Recursive pre-order walk that yields every node whose `nodeType`
/// field matches `"Test Case"`. The xcresulttool JSON is a nested
/// `testNodes` tree of suites and cases; this flattens the leaf cases
/// without losing the identifier we need to filter on the gate suite.
func walkTestCases(_ node: Any, into acc: inout [[String: Any]]) {
  if let dict = node as? [String: Any] {
    if (dict["nodeType"] as? String) == "Test Case" {
      acc.append(dict)
    }
    if let children = dict["children"] as? [Any] {
      for child in children { walkTestCases(child, into: &acc) }
    }
  } else if let array = node as? [Any] {
    for item in array { walkTestCases(item, into: &acc) }
  }
}

let rootDict = (root as? [String: Any]) ?? [:]
let topNodes: Any = rootDict["testNodes"] ?? []
var flattened: [[String: Any]] = []
walkTestCases(topNodes, into: &flattened)

var byName: [String: [String: Any]] = [:]
let knownNames = Set(gateBudgets.map(\.name))
for caseNode in flattened {
  let identifier = (caseNode["nodeIdentifier"] as? String) ?? ""
  guard identifier.contains("VirtualListPerformanceGates") else { continue }
  var name = (caseNode["name"] as? String) ?? ""
  if name.hasSuffix("()") { name = String(name.dropLast(2)) }
  if knownNames.contains(name) { byName[name] = caseNode }
}

let iconByResult: [String: String] = [
  "Passed": "✅",
  "Failed": "❌",
  "Skipped": "⏭",
]
var summary: [String: Any] = [:]
for (name, budget) in gateBudgets {
  guard let caseNode = byName[name] else {
    print("| `\(name)` | \(budget) | ⚠ not run | – |")
    summary[name] = NSNull()
    continue
  }
  let result = (caseNode["result"] as? String) ?? "?"
  let icon = iconByResult[result] ?? "❓"
  let duration = (caseNode["duration"] as? String) ?? "?"
  print("| `\(name)` | \(budget) | \(icon) \(result) | \(duration) |")
  summary[name] = result
}

if let json = try? JSONSerialization.data(
  withJSONObject: summary,
  options: [.sortedKeys]
) {
  FileHandle.standardError.write(json)
}
