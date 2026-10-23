// OWNER: HOM-24
//
// The Flutter-free text core (ARCH v1.2 §8 "PDF text (search)"): `PDFPage.string` extraction for
// the search index (AIS-50's DocumentTextPort) and the viewer's in-document search, page by page so
// a newer search can cancel an older one between pages. Matching is case- and diacritic-insensitive
// unless asked otherwise; offsets are UTF-16 units into the page text. Nothing here logs document
// text or queries (rule 30).

import CoreGraphics
import Foundation
import PDFKit

/// The text of one page.
struct PdfTextPage: Equatable {
  let index: Int
  let text: String
}

/// Extracted text of a page range.
struct PdfTextExtraction: Equatable {
  let documentPageCount: Int
  let pages: [PdfTextPage]
  let truncated: Bool
}

/// One search match.
struct PdfSearchMatch: Equatable {
  let pageIndex: Int
  let rangeStart: Int
  let rangeLength: Int
  let snippet: String
  let snippetMatchStart: Int
  let snippetMatchLength: Int
  let bounds: CGRect
}

/// The matches of one search.
struct PdfSearchOutcome: Equatable {
  let matches: [PdfSearchMatch]
  let truncated: Bool
}

enum PdfTextExtractor {
  /// Text of `pageCount` pages (-1: to the end) from `firstPage` of the file at [path], opened
  /// read-only; stops after [maxChars] UTF-16 units in total (-1: no limit).
  static func extract(
    path: String, password: String?, firstPage: Int, pageCount: Int, maxChars: Int,
    isCancelled: () -> Bool = { false }
  ) throws -> PdfTextExtraction {
    let document = try PdfReader.open(path: path, password: password)
    if document.isLocked { throw PdfFailure(.passwordRequired, "document is locked") }
    return try extract(document, firstPage: firstPage, pageCount: pageCount, maxChars: maxChars, isCancelled: isCancelled)
  }

  static func extract(
    _ document: PDFDocument, firstPage: Int, pageCount: Int, maxChars: Int, isCancelled: () -> Bool = { false }
  ) throws -> PdfTextExtraction {
    guard firstPage >= 0, pageCount >= -1 else { throw PdfFailure(.invalidArgument, "bad page range") }
    let total = document.pageCount
    let end = pageCount < 0 ? total : min(total, firstPage + pageCount)
    var pages: [PdfTextPage] = []
    var used = 0
    var truncated = false
    if firstPage < end {
      for i in firstPage..<end {
        if isCancelled() { throw PdfFailure(.cancelled, "cancelled") }
        var text = document.page(at: i)?.string ?? ""
        if maxChars >= 0 {
          let units = (text as NSString).length
          if used + units > maxChars {
            let keep = max(0, maxChars - used)
            text = (text as NSString).substring(to: keep)
            pages.append(PdfTextPage(index: i, text: text))
            truncated = true
            break
          }
          used += units
        }
        pages.append(PdfTextPage(index: i, text: text))
      }
    }
    return PdfTextExtraction(documentPageCount: total, pages: pages, truncated: truncated)
  }
}

enum PdfSearcher {
  /// Characters of context on each side of a match in its snippet.
  static let context = 40

  /// Finds [query] in [document] page by page.
  static func search(
    _ document: PDFDocument, query: String, caseSensitive: Bool, maxHits: Int, isCancelled: () -> Bool = { false }
  ) throws -> PdfSearchOutcome {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty, maxHits > 0 else { return PdfSearchOutcome(matches: [], truncated: false) }
    if document.isLocked { throw PdfFailure(.passwordRequired, "document is locked") }
    let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    var matches: [PdfSearchMatch] = []
    for i in 0..<document.pageCount {
      if isCancelled() { throw PdfFailure(.cancelled, "cancelled") }
      guard let page = document.page(at: i), let string = page.string, !string.isEmpty else { continue }
      let text = string as NSString
      var from = 0
      while from < text.length {
        let found = text.range(of: needle, options: options, range: NSRange(location: from, length: text.length - from))
        if found.location == NSNotFound { break }
        if matches.count == maxHits { return PdfSearchOutcome(matches: matches, truncated: true) }
        matches.append(match(on: page, index: i, text: text, range: found))
        from = found.location + max(1, found.length)
      }
    }
    return PdfSearchOutcome(matches: matches, truncated: false)
  }

  static func match(on page: PDFPage, index: Int, text: NSString, range: NSRange) -> PdfSearchMatch {
    let start = max(0, range.location - context)
    let end = min(text.length, range.location + range.length + context)
    let raw = text.substring(with: NSRange(location: start, length: end - start))
    // One line: newlines and tabs become spaces (same UTF-16 length, so offsets stay valid).
    let snippet = raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
    let bounds = page.selection(for: range)?.bounds(for: page) ?? .zero
    return PdfSearchMatch(
      pageIndex: index, rangeStart: range.location, rangeLength: range.length, snippet: snippet,
      snippetMatchStart: range.location - start, snippetMatchLength: range.length, bounds: bounds)
  }
}
