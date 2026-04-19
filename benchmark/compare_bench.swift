#!/usr/bin/env swift
//
// compare_bench.swift — reads a `xcodebuild test` / `swift test` log that
// contains `ListVsVirtualListBenchmarks` output, pairs the `test_list_*` /
// `test_updateList_*` rows with their `test_virtualList_*` /
// `test_updateVirtualList_*` counterparts, and prints a markdown table
// with robust statistics:
//
//   - **Median** as the representative value (not mean). Benchmark
//     distributions are heavy-tailed; the mean is dragged around by a
//     handful of slow samples, the median is not.
//   - **IQR / MAD** for spread, and a visible outlier count via the
//     Tukey rule (below Q1 − 1.5·IQR or above Q3 + 1.5·IQR). Outliers
//     are **flagged, never silently dropped** — an ad-hoc "SD too
//     high, rerun" loop is the textbook shape of post-hoc selection
//     bias.
//   - **Mann-Whitney U** rank-sum test for the pair-vs-pair comparison
//     (not a Welch t-test on the mean). No normality assumption; the
//     null is "samples from the two engines are exchangeable". With
//     `n_L = n_VL = 100`, the normal approximation on U is tight, so
//     we report |z| directly and mark `tied` when |z| < 3.
//
// Usage:
//     swift benchmark/compare_bench.swift path/to/bench.log [section]
//
// `section` optional filter: `range`, `collection`, `update`.
//

import Foundation

// MARK: - Parsing

struct Sample {
  let name: String
  let values: [Double]      // seconds per operation, raw samples
}

let startPattern = #"Test Case '-\[VirtualListTests\.ListVsVirtualListBenchmarks (\S+)\]' started"#
let metricPattern =
  #"Clock Monotonic Time, s\] average: ([\d.]+), relative standard deviation: ([\d.]+)%, values: \[([^\]]+)\]"#

let startRegex = try! NSRegularExpression(pattern: startPattern)
let metricRegex = try! NSRegularExpression(pattern: metricPattern)

func parse(_ log: String) -> [Sample] {
  var samples: [Sample] = []
  var current: String?

  for line in log.split(whereSeparator: \.isNewline) {
    let s = String(line)
    let range = NSRange(s.startIndex..<s.endIndex, in: s)

    if let m = startRegex.firstMatch(in: s, range: range),
      let r = Range(m.range(at: 1), in: s)
    {
      current = String(s[r])
      continue
    }

    guard
      let m = metricRegex.firstMatch(in: s, range: range),
      let name = current,
      let valsRange = Range(m.range(at: 3), in: s)
    else { continue }

    let vals = String(s[valsRange])
      .split(separator: ",")
      .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

    guard vals.count >= 2 else {
      current = nil
      continue
    }

    samples.append(Sample(name: name, values: vals))
    current = nil
  }

  return samples
}

// MARK: - Robust summary statistics

/// Sorted-array percentile via linear interpolation. `p ∈ [0, 1]`.
func percentile(_ sorted: [Double], _ p: Double) -> Double {
  guard !sorted.isEmpty else { return 0 }
  let idx = p * Double(sorted.count - 1)
  let lo = Int(floor(idx))
  let hi = Int(ceil(idx))
  if lo == hi { return sorted[lo] }
  let frac = idx - Double(lo)
  return sorted[lo] * (1 - frac) + sorted[hi] * frac
}

struct RobustSummary {
  let n: Int
  let min: Double
  let q1: Double
  let median: Double
  let q3: Double
  let max: Double
  let iqr: Double
  /// Count of values outside `[Q1 − 1.5·IQR, Q3 + 1.5·IQR]` (Tukey rule).
  let outliers: Int
}

func summarize(_ values: [Double]) -> RobustSummary {
  let sorted = values.sorted()
  let q1 = percentile(sorted, 0.25)
  let median = percentile(sorted, 0.5)
  let q3 = percentile(sorted, 0.75)
  let iqr = q3 - q1
  let lower = q1 - 1.5 * iqr
  let upper = q3 + 1.5 * iqr
  let outliers = sorted.reduce(0) { $0 + ($1 < lower || $1 > upper ? 1 : 0) }
  return RobustSummary(
    n: sorted.count,
    min: sorted.first ?? 0,
    q1: q1,
    median: median,
    q3: q3,
    max: sorted.last ?? 0,
    iqr: iqr,
    outliers: outliers
  )
}

// MARK: - Mann-Whitney U

/// Assigns 1-based ranks with average-rank handling for ties.
/// Returns ranks in the original index order of `values`.
func ranks(of values: [Double]) -> [Double] {
  let indexed = values.enumerated().sorted { $0.element < $1.element }
  var out = Array(repeating: 0.0, count: values.count)
  var i = 0
  while i < indexed.count {
    var j = i
    while j + 1 < indexed.count, indexed[j + 1].element == indexed[i].element {
      j += 1
    }
    // Average of ranks [i+1 … j+1] in 1-based terms.
    let avg = Double(i + 1 + j + 1) / 2.0
    for k in i...j {
      out[indexed[k].offset] = avg
    }
    i = j + 1
  }
  return out
}

struct MannWhitney {
  /// |z| from the normal approximation on U. With n₁ = n₂ = 100, this
  /// approximation is tight; small-n corrections are not applied.
  let z: Double
  /// `"L"` or `"VL"` — whichever side has the smaller median. `nil` if
  /// medians are exactly equal.
  let winner: String?
  /// Ratio of medians, always ≥ 1.
  let ratio: Double
}

func mannWhitney(
  list: [Double],
  vl: [Double],
  listMedian: Double,
  vlMedian: Double
) -> MannWhitney {
  let combined = list + vl
  let combinedRanks = ranks(of: combined)
  let listRanks = combinedRanks.prefix(list.count)
  let rSumList = listRanks.reduce(0, +)
  let n1 = Double(list.count)
  let n2 = Double(vl.count)
  let uList = rSumList - n1 * (n1 + 1) / 2
  let uVL = n1 * n2 - uList
  let u = Swift.min(uList, uVL)
  let muU = n1 * n2 / 2
  let sigmaU = ((n1 * n2 * (n1 + n2 + 1)) / 12).squareRoot()
  let z = sigmaU == 0 ? 0 : (muU - u) / sigmaU  // direction absorbed by `winner`

  let winner: String?
  if listMedian < vlMedian {
    winner = "L"
  } else if vlMedian < listMedian {
    winner = "VL"
  } else {
    winner = nil
  }
  let ratio = listMedian > vlMedian
    ? listMedian / vlMedian
    : vlMedian / listMedian
  return MannWhitney(z: z, winner: winner, ratio: ratio)
}

// MARK: - Pairing

struct Pair {
  let label: String
  let countForSort: Int
  let list: Sample
  let vl: Sample
}

let countLabelToInt: [(label: String, value: Int)] = [
  ("10", 10),
  ("20", 20),
  ("50", 50),
  ("100", 100),
  ("500", 500),
  ("1k", 1_000),
  ("10k", 10_000),
  ("100k", 100_000),
  ("1M", 1_000_000),
]

func countLabel(of name: String) -> (String, Int)? {
  for (label, v) in countLabelToInt where name.hasSuffix("_\(label)") {
    return (label, v)
  }
  return nil
}

func vlTwin(of listName: String) -> String? {
  if listName.hasPrefix("test_list_") {
    return "test_virtualList_" + String(listName.dropFirst("test_list_".count))
  }
  if listName.hasPrefix("test_updateList_") {
    return "test_updateVirtualList_" + String(listName.dropFirst("test_updateList_".count))
  }
  return nil
}

enum Section: String, CaseIterable {
  case rangeInit = "range"
  case collectionInit = "collection"
  case update

  static func classify(_ name: String) -> Section? {
    if name.contains("updateList_") || name.contains("updateVirtualList_") {
      return .update
    }
    if name.contains("_range_") { return .rangeInit }
    if name.contains("_collection_") { return .collectionInit }
    return nil
  }

  var heading: String {
    switch self {
    case .rangeInit: "Initial render (Range shape, ms per render)"
    case .collectionInit: "Initial render (Array-of-Identifiable, ms per render)"
    case .update: "Per-update (single-item flip, ms per flip)"
    }
  }
}

// MARK: - Formatting

func formatMS(_ seconds: Double) -> String {
  String(format: "%.2f", seconds * 1000)
}

func formatPct(_ frac: Double) -> String {
  String(format: "%.1f%%", frac * 100)
}

/// Markdown cell for verdict. `|z| < 3` → `tied`; otherwise
/// `"<winner> <ratio>×"`.
func verdictCell(mw: MannWhitney, threshold: Double = 3.0) -> String {
  guard abs(mw.z) >= threshold, let winner = mw.winner else {
    return "tied"
  }
  return String(format: "%@ %.2f×", winner, mw.ratio)
}

// MARK: - Entry

guard CommandLine.arguments.count >= 2 else {
  FileHandle.standardError.write(
    Data("usage: compare_bench.swift <log> [section]\n".utf8)
  )
  exit(1)
}
let logPath = CommandLine.arguments[1]
let sectionArg = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : nil

guard let log = try? String(contentsOfFile: logPath, encoding: .utf8) else {
  FileHandle.standardError.write(Data("cannot read \(logPath)\n".utf8))
  exit(1)
}

let samples = parse(log)
var byName: [String: Sample] = [:]
for s in samples { byName[s.name] = s }

var pairsBySection: [Section: [Pair]] = [:]
for sample in samples where sample.name.hasPrefix("test_list_") || sample.name.hasPrefix("test_updateList_") {
  guard
    let twinName = vlTwin(of: sample.name),
    let twin = byName[twinName],
    let (label, value) = countLabel(of: sample.name),
    let section = Section.classify(sample.name)
  else { continue }

  let pair = Pair(label: label, countForSort: value, list: sample, vl: twin)
  pairsBySection[section, default: []].append(pair)
}

let sectionsToPrint: [Section] = sectionArg
  .flatMap { Section(rawValue: $0).map { [$0] } }
  ?? Section.allCases

for section in sectionsToPrint {
  guard let pairs = pairsBySection[section], !pairs.isEmpty else { continue }
  let sorted = pairs.sorted { $0.countForSort < $1.countForSort }

  print("**\(section.heading):**")
  print("")
  print("| N | `List` median (IQR, outliers) | `VirtualList` median (IQR, outliers) | Verdict (Mann-Whitney U, \\|z\\|≥3) |")
  print("|---:|---:|---:|:---|")

  for pair in sorted {
    let lSummary = summarize(pair.list.values)
    let vSummary = summarize(pair.vl.values)
    let mw = mannWhitney(
      list: pair.list.values,
      vl: pair.vl.values,
      listMedian: lSummary.median,
      vlMedian: vSummary.median
    )

    let lMed = formatMS(lSummary.median)
    let lIQR = formatMS(lSummary.iqr)
    let vMed = formatMS(vSummary.median)
    let vIQR = formatMS(vSummary.iqr)

    let lOut = lSummary.outliers == 0 ? "0" : "\(lSummary.outliers)⚠"
    let vOut = vSummary.outliers == 0 ? "0" : "\(vSummary.outliers)⚠"

    let verdict = verdictCell(mw: mw)
    let lCell = "\(lMed) (IQR \(lIQR), \(lOut))"
    let vCell = "\(vMed) (IQR \(vIQR), \(vOut))"
    print("| \(pair.label) | \(lCell) | \(vCell) | \(verdict) |")
  }
  print("")
}

// Summary of outlier counts, so a high-outlier cell is easy to locate
// without re-reading the tables.
var totalOutliers = 0
for pairs in pairsBySection.values {
  for pair in pairs {
    totalOutliers += summarize(pair.list.values).outliers
    totalOutliers += summarize(pair.vl.values).outliers
  }
}
if totalOutliers > 0 {
  print("Outlier marker (⚠) = sample sat outside `[Q1 − 1.5·IQR, Q3 + 1.5·IQR]` (Tukey rule). Flagged, not dropped — the median-based headline is robust to them either way. Total flagged samples across the run: \(totalOutliers).")
}
