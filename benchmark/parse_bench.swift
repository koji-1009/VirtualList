#!/usr/bin/env swift
//
// parse_bench.swift — extracts per-test clock averages from a
// `xcodebuild test` / `swift test` log file produced by
// ListVsVirtualListBenchmarks. Usage:
//
//     swift benchmark/parse_bench.swift path/to/bench.log [filter]
//
// `filter` is optional; when supplied, only rows whose test name
// contains the substring are printed.
//

import Foundation

guard CommandLine.arguments.count >= 2 else {
  FileHandle.standardError.write(Data("usage: parse_bench.swift <log> [filter]\n".utf8))
  exit(1)
}
let path = CommandLine.arguments[1]
let filter = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : nil

guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
  FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
  exit(1)
}

let startPattern = #"Test Case '-\[VirtualListTests\.ListVsVirtualListBenchmarks (\S+)\]' started"#
let metricPattern = #"Clock Monotonic Time, s\] average: ([\d.]+), relative standard deviation: ([\d.]+)%, values: \[([^\]]+)\]"#
let startRegex = try! NSRegularExpression(pattern: startPattern)
let metricRegex = try! NSRegularExpression(pattern: metricPattern)

struct Row {
  let name: String
  let avgMS: Double
  let minMS: Double
  let maxMS: Double
  let sd: Double
  let count: Int
}

var current: String?
var rows: [Row] = []
for line in data.split(whereSeparator: \.isNewline) {
  let s = String(line)
  let range = NSRange(s.startIndex..<s.endIndex, in: s)

  if let m = startRegex.firstMatch(in: s, range: range),
    let r = Range(m.range(at: 1), in: s)
  {
    current = String(s[r])
    continue
  }
  if let m = metricRegex.firstMatch(in: s, range: range),
    let name = current,
    let valsRange = Range(m.range(at: 3), in: s),
    let sdRange = Range(m.range(at: 2), in: s)
  {
    let valsStr = String(s[valsRange])
    let vals = valsStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard !vals.isEmpty else {
      current = nil
      continue
    }
    let avg = vals.reduce(0, +) / Double(vals.count)
    let minV = vals.min() ?? 0
    let maxV = vals.max() ?? 0
    let sd = Double(String(s[sdRange])) ?? 0
    rows.append(Row(
      name: name,
      avgMS: avg * 1000,
      minMS: minV * 1000,
      maxMS: maxV * 1000,
      sd: sd,
      count: vals.count
    ))
    current = nil
  }
}

let filtered = filter.map { f in rows.filter { $0.name.contains(f) } } ?? rows
for row in filtered.sorted(by: { $0.name < $1.name }) {
  let namePadded = row.name.padding(toLength: 40, withPad: " ", startingAt: 0)
  print(String(
    format: "%@ n=%2d avg=%7.2f min=%7.2f max=%7.2f sd=%5.1f%%",
    namePadded, row.count, row.avgMS, row.minMS, row.maxMS, row.sd
  ))
}
