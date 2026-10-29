// OWNER: HOM-30
//
// The Flutter-free geometry of the sign mode (HOM plan §8.5): moving and resizing a signature stamp
// in Pigeon page space (origin at the crop box's bottom-left, unrotated). The viewer
// (Annotate/PdfAnnotateView.swift, input `place`) converts touches to page points and asks these
// functions for the stamp's next rect, so a stamp always stays on its page, never gets smaller than
// [PdfSignGeometry.minSide] and keeps its aspect ratio while resizing. XCTest runs this file without
// Flutter (Tests/Sign/Core/).

import CoreGraphics
import Foundation

/// Moving and resizing a stamp on its page.
enum PdfSignGeometry {
  /// A resized stamp's shorter side is at least this long (points).
  static let minSide: CGFloat = 12

  /// The handle disc's diameter on screen (view points); its touch target is [handleReach] around
  /// its centre (a 44 pt target).
  static let handleDiameter: CGFloat = 22
  static let handleReach: CGFloat = 22

  /// [rect] moved by [delta], kept inside [page] (a rect larger than the page is pinned to its
  /// bottom-left corner).
  static func moved(_ rect: CGRect, by delta: CGVector, within page: CGRect) -> CGRect {
    var x = rect.minX + delta.dx
    var y = rect.minY + delta.dy
    x = min(max(x, page.minX), max(page.minX, page.maxX - rect.width))
    y = min(max(y, page.minY), max(page.minY, page.maxY - rect.height))
    return CGRect(x: x, y: y, width: rect.width, height: rect.height)
  }

  /// [rect] resized with its [handle] corner dragged to [point] while the opposite corner stays,
  /// aspect ratio kept, at least [minSide] on its shorter side and inside [page].
  static func resized(_ rect: CGRect, handle: CGPoint, to point: CGPoint, within page: CGRect) -> CGRect {
    guard rect.width > 0, rect.height > 0 else { return rect }
    let anchor = CGPoint(x: handle.x <= rect.midX ? rect.maxX : rect.minX, y: handle.y <= rect.midY ? rect.maxY : rect.minY)
    let sx: CGFloat = handle.x <= rect.midX ? -1 : 1
    let sy: CGFloat = handle.y <= rect.midY ? -1 : 1
    // The scale that puts the corner nearest to the point along the drag, then the limits.
    let wanted = max((point.x - anchor.x) * sx / rect.width, (point.y - anchor.y) * sy / rect.height)
    let smallest = minSide / min(rect.width, rect.height)
    let roomX = (sx > 0 ? page.maxX - anchor.x : anchor.x - page.minX) / rect.width
    let roomY = (sy > 0 ? page.maxY - anchor.y : anchor.y - page.minY) / rect.height
    let largest = max(smallest, min(roomX, roomY))
    let scale = min(max(wanted.isFinite ? wanted : 1, smallest), largest)
    let w = rect.width * scale
    let h = rect.height * scale
    return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
  }

  /// The corner of [rect] (page space) shown lowest and most trailing on screen, given the
  /// page-to-screen mapping [toScreen] (screen y grows downwards).
  static func handleCorner(of rect: CGRect, toScreen: (CGPoint) -> CGPoint) -> CGPoint {
    let corners = [
      CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
    ]
    return corners.max { a, b in
      let sa = toScreen(a)
      let sb = toScreen(b)
      return sa.x + sa.y < sb.x + sb.y
    } ?? CGPoint(x: rect.maxX, y: rect.minY)
  }
}
