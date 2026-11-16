import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PairedFile: Sendable {
  static let maxBytes = 5 * 1024 * 1024
  static let maxWireBytes = 8 * 1024 * 1024
  private static let maxMetadata = 2048
  static let maxPayload = 4 + maxMetadata + maxBytes

  let name: String
  let mime: String
  let data: Data
  let imageType: UTType?

  init(name: String, mime: String, data: Data) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      name != ".", name != "..", name.utf8.count <= 255,
      !name.contains("/"), !name.contains("\\"),
      name.unicodeScalars.allSatisfy({
        !(0...31).contains($0.value) && !(127...159).contains($0.value)
      }),
      mime.wholeMatch(of: #/[A-Za-z0-9!#$&^_.+\-]{1,64}/[A-Za-z0-9!#$&^_.+\-]{1,64}/#) != nil,
      data.count <= Self.maxBytes
    else { throw Rejected.invalid }
    self.name = name
    self.mime = mime
    self.data = data
    imageType = Self.detectImageType(in: data)
  }

  private static func detectImageType(in data: Data) -> UTType? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let identifier = CGImageSourceGetType(source) as String?,
      let type = UTType(identifier), type.conforms(to: .image)
    else { return nil }
    // ImageIO can identify a truncated image from its header. Require pixels.
    let options =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 32,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options) == nil ? nil : type
  }

  func encode() throws -> Data {
    let metadata = try json(["name": name, "mime": mime])
    guard metadata.count <= Self.maxMetadata else { throw Rejected.invalid }
    var count = UInt32(metadata.count).bigEndian
    return withUnsafeBytes(of: &count) { Data($0) } + metadata + data
  }

  static func decode(_ payload: Data) throws -> Self {
    guard (5...maxPayload).contains(payload.count) else { throw Rejected.invalid }
    let length = payload.prefix(4).reduce(0) { $0 * 256 + Int($1) }
    guard (1...maxMetadata).contains(length), length <= payload.count - 4
    else { throw Rejected.invalid }
    let metadata = try StrictJSON.decodeObject(Data(payload.dropFirst(4).prefix(length)))
    try fields(metadata, "name mime")
    return try Self(
      name: text(metadata, "name"), mime: text(metadata, "mime"),
      data: Data(payload.dropFirst(4 + length)))
  }
}

func queuedFileResponse(
  key: Data, request: Object, id: String, payload: Data
) throws -> Object {
  let aad = try
    "bridge-v2/file-response|\(text(request, "pairing_id"))|\(text(request, "message_id"))|\(id)"
  let sealed = try ChaChaPoly.seal(
    payload, using: SymmetricKey(data: key), authenticating: utf8(aad))
  return ["file_id": id, "sealed": sealed.combined.base64EncodedString()]
}
