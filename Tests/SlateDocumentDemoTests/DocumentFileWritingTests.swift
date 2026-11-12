import Foundation
import SystemPackage
import Testing

@testable import SlateDocumentDemo

@Test func documentWriteStreamsBytesWithoutChangingDiskUntilCommitAndCanSaveAgain() throws {
  let fixture = try DocumentWriteFixture("original\r\n")
  var identity = try fixture.identity()
  let originalIdentity = identity
  let content = "edited\r\n👩‍💻\0\n"
  do {
    var save = try DocumentFileWrite(fixture.path, expectedIdentity: identity, expectedByteCount: content.utf8.count)
    try save.append(content.utf8Span.span)
    #expect(save.bytesWritten == content.utf8.count)
    #expect(try fixture.contents() == Data("original\r\n".utf8))
    identity = try save.commit()
  }
  #expect(try fixture.contents() == Data(content.utf8))
  #expect(identity == (try fixture.identity()))
  #expect(identity.inode != originalIdentity.inode)
  do {
    var save = try DocumentFileWrite(fixture.path, expectedIdentity: identity, expectedByteCount: 0)
    identity = try save.commit()
  }
  #expect(try fixture.contents().isEmpty)
  #expect(identity == (try fixture.identity()))
  #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func documentWriteAbandonmentAndIncompleteCommitPreserveOriginalAndCleanTemporaryFiles() throws {
  let fixture = try DocumentWriteFixture("original")
  let identity = try fixture.identity()
  do {
    var save = try DocumentFileWrite(fixture.path, expectedIdentity: identity, expectedByteCount: 7)
    try save.append("partial".utf8Span.span)
    #expect(try fixture.temporaryFiles().count == 1)
  }
  #expect(try fixture.temporaryFiles().isEmpty)
  #expect(try fixture.contents() == Data("original".utf8))
  do {
    var save = try DocumentFileWrite(fixture.path, expectedIdentity: identity, expectedByteCount: 8)
    try save.append("partial".utf8Span.span)
    #expect(throws: DocumentFileWriteError.incompleteWrite) { try save.commit() }
  }
  #expect(try fixture.temporaryFiles().isEmpty)
  #expect(try fixture.identity() == identity)
}

@Test func documentWriteDetectsExternalEditsAndPathReplacement() throws {
  let fixture = try DocumentWriteFixture("original")
  let identity = try fixture.identity()
  do {
    var save = try DocumentFileWrite(fixture.path, expectedIdentity: identity, expectedByteCount: 5)
    try save.append("local".utf8Span.span)
    try Data("external".utf8).write(to: fixture.url, options: .atomic)
    #expect(throws: DocumentFileWriteError.fileChanged) { try save.commit() }
  }
  #expect(try fixture.contents() == Data("external".utf8))
  #expect(try fixture.temporaryFiles().isEmpty)
  #expect(throws: DocumentFileWriteError.fileChanged) {
    _ = try DocumentFileWrite(fixture.path, expectedIdentity: identity, expectedByteCount: 5)
  }
  let secondIdentity = try fixture.identity()
  do {
    var save = try DocumentFileWrite(fixture.path, expectedIdentity: secondIdentity, expectedByteCount: 5)
    try save.append("local".utf8Span.span)
    let handle = try FileHandle(forWritingTo: fixture.url)
    try handle.write(contentsOf: Data("changed!".utf8))
    try handle.close()
    #expect(throws: DocumentFileWriteError.fileChanged) { try save.commit() }
  }
  #expect(try fixture.contents() == Data("changed!".utf8))
  #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func documentWritePreservesPOSIXPermissions() throws {
  let fixture = try DocumentWriteFixture("original")
  try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: fixture.path)
  let oldStatus = try Stat(FilePath(fixture.path))
  do {
    var save = try DocumentFileWrite(fixture.path, expectedIdentity: try fixture.identity(), expectedByteCount: 3)
    try save.append("new".utf8Span.span)
    _ = try save.commit()
  }
  let newStatus = try Stat(FilePath(fixture.path))
  #expect(newStatus.permissions == oldStatus.permissions)
  #expect(newStatus.userID == oldStatus.userID && newStatus.groupID == oldStatus.groupID)
}

@Test func documentWriteRejectsLinksWithoutChangingTheirTargets() throws {
  let fixture = try DocumentWriteFixture("original")
  let symbolicPath = fixture.directory.appendingPathComponent("symbolic").path
  try FileManager.default.createSymbolicLink(atPath: symbolicPath, withDestinationPath: fixture.path)
  #expect(throws: DocumentFileWriteError.unsupportedFile) {
    _ = try DocumentFileWrite(symbolicPath, expectedIdentity: try fixture.identity(), expectedByteCount: 0)
  }
  let hardPath = fixture.directory.appendingPathComponent("hard").path
  try FileManager.default.linkItem(atPath: fixture.path, toPath: hardPath)
  #expect(throws: DocumentFileWriteError.unsupportedFile) {
    _ = try DocumentFileWrite(fixture.path, expectedIdentity: try fixture.identity(), expectedByteCount: 0)
  }
  #expect(try fixture.contents() == Data("original".utf8))
  #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func documentWriteBoundsChunksAndTotalLengthAndStreamsLargerFiles() throws {
  let fixture = try DocumentWriteFixture("original")
  let identity = try fixture.identity()
  let chunk = String(repeating: "x", count: DocumentFileWrite.maximumChunkBytes)
  do {
    var save = try DocumentFileWrite(fixture.path, expectedIdentity: identity, expectedByteCount: chunk.utf8.count * 2)
    try save.append(chunk.utf8Span.span)
    try save.append(chunk.utf8Span.span)
    #expect(save.bytesWritten == chunk.utf8.count * 2)
    _ = try save.commit()
  }
  let saved = try fixture.contents()
  #expect(saved.count == chunk.utf8.count * 2)
  #expect(saved.allSatisfy { $0 == 0x78 })
  let updatedIdentity = try fixture.identity()
  do {
    var save = try DocumentFileWrite(fixture.path, expectedIdentity: updatedIdentity, expectedByteCount: 0)
    #expect(throws: DocumentFileWriteError.invalidChunk) { try save.append("x".utf8Span.span) }
  }
  do {
    let excessiveChunk = chunk + "x"
    var save = try DocumentFileWrite(
      fixture.path, expectedIdentity: updatedIdentity, expectedByteCount: excessiveChunk.utf8.count)
    #expect(throws: DocumentFileWriteError.invalidChunk) { try save.append(excessiveChunk.utf8Span.span) }
  }
  #expect(try fixture.identity() == updatedIdentity)
  #expect(try fixture.temporaryFiles().isEmpty)
}

@Test func documentWriteSaveAsCreatesNewDestinationAndRefusesExistingOrRacingDestinations() throws {
  let fixture = try DocumentWriteFixture("original")
  let destination = fixture.directory.appendingPathComponent("new-name")
  let originalIdentity = try fixture.identity()
  do {
    var save = try DocumentFileWrite(destination.path, expectedIdentity: nil, expectedByteCount: 6)
    try save.append("edited".utf8Span.span)
  }
  #expect(!FileManager.default.fileExists(atPath: destination.path))
  #expect(try fixture.temporaryFiles().isEmpty)
  do {
    var save = try DocumentFileWrite(destination.path, expectedIdentity: nil, expectedByteCount: 6)
    try save.append("edited".utf8Span.span)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let identity = try save.commit()
    let saved = try OwnedDocumentFile.open(destination.path)
    #expect(identity == (try saved.identity()))
  }
  #expect(try Data(contentsOf: destination) == Data("edited".utf8))
  #expect(try fixture.identity() == originalIdentity)
  #expect(try fixture.contents() == Data("original".utf8))
  #expect(throws: DocumentFileWriteError.destinationExists) {
    _ = try DocumentFileWrite(destination.path, expectedIdentity: nil, expectedByteCount: 0)
  }
  let racedDestination = fixture.directory.appendingPathComponent("raced-name")
  do {
    var save = try DocumentFileWrite(racedDestination.path, expectedIdentity: nil, expectedByteCount: 0)
    try Data("competitor".utf8).write(to: racedDestination, options: .withoutOverwriting)
    #expect(throws: DocumentFileWriteError.destinationExists) { try save.commit() }
  }
  #expect(try Data(contentsOf: racedDestination) == Data("competitor".utf8))
  #expect(try fixture.temporaryFiles().isEmpty)
}

private struct DocumentWriteFixture: ~Copyable {
  let directory: URL
  let url: URL
  var path: String { url.path }

  init(_ content: String) throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "slate-write-tests-" + UUID().uuidString)
    url = directory.appendingPathComponent("document")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try Data(content.utf8).write(to: url, options: .withoutOverwriting)
  }

  borrowing func identity() throws -> DocumentFileIdentity {
    let file = try OwnedDocumentFile.open(path)
    return try file.identity()
  }

  borrowing func contents() throws -> Data { try Data(contentsOf: url) }

  borrowing func temporaryFiles() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".slate-write-") }
  }

  deinit { try? FileManager.default.removeItem(at: directory) }
}
