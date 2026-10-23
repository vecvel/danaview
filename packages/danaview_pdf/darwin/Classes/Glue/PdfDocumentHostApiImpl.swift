// OWNER: HOM-24
//
// PdfDocumentHostApi on Apple over the PdfDocumentStore (Viewer/PdfCore.swift): opens run on a
// background queue and reply on the main thread (Flutter's channel threading rule); sources are
// opened read-only (rule 27). The outline is read from an independent open (`store.twin`), never
// from the document a PDFView draws on the main thread (PDFKit is not thread-safe).

import Foundation

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

final class PdfDocumentHostApiImpl: PdfDocumentHostApi {
  let store: PdfDocumentStore
  private let queue = DispatchQueue(label: "com.vecvel.danaview.pdf.documents", qos: .userInitiated, attributes: .concurrent)

  init(store: PdfDocumentStore) {
    self.store = store
  }

  func capabilities() throws -> PdfCapabilitiesMsg {
    PdfCapabilitiesMsg(
      platformView: true, textureView: false, search: true, selection: true, outline: true, passwords: true,
      textExtraction: true,
      tools: PdfPageTools.supported + PdfAnnotator.supported + PdfSigner.supported + PdfCompressor.supported)
  }

  private func background<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ body: @escaping () throws -> T) {
    queue.async {
      let result: Result<T, Error>
      do {
        result = .success(try body())
      } catch {
        result = .failure(PdfErrors.from(error))
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func probe(path: String, completion: @escaping (Result<PdfProbeMsg, Error>) -> Void) {
    background(completion) {
      let probe = try PdfReader.probe(path: path)
      return PdfProbeMsg(canOpen: probe.canOpen, encrypted: probe.encrypted, pageCount: Int64(probe.pageCount))
    }
  }

  func open(request: PdfOpenRequestMsg, completion: @escaping (Result<PdfDocumentInfoMsg, Error>) -> Void) {
    background(completion) { [store] in
      PdfDocumentHostApiImpl.message(try store.open(path: request.path, password: request.password))
    }
  }

  func unlock(handle: Int64, password: String, completion: @escaping (Result<PdfDocumentInfoMsg?, Error>) -> Void) {
    background(completion) { [store] in
      try store.unlock(handle: handle, password: password).map(PdfDocumentHostApiImpl.message)
    }
  }

  func outline(handle: Int64, completion: @escaping (Result<[PdfOutlineItemMsg], Error>) -> Void) {
    background(completion) { [store] in
      PdfReader.outline(of: try store.twin(handle)).map {
        PdfOutlineItemMsg(title: $0.title, pageIndex: Int64($0.pageIndex), depth: Int64($0.depth))
      }
    }
  }

  func close(handle: Int64) throws {
    store.close(handle)
  }

  static func message(_ s: PdfDocumentSummary) -> PdfDocumentInfoMsg {
    PdfDocumentInfoMsg(
      handle: s.handle, pageCount: Int64(s.pageCount), encrypted: s.encrypted, locked: s.locked,
      allowsCopying: s.allowsCopying, allowsPrinting: s.allowsPrinting,
      pageSizes: s.pages.map { PdfPageSizeMsg(width: $0.width, height: $0.height, rotation: Int64($0.rotation)) },
      title: s.title)
  }
}
