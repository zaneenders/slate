import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
import Musl
#endif

enum DocumentFileWriteError: Error, Equatable, Sendable {
  case invalidPath
  case invalidByteCount
  case invalidChunk
  case incompleteWrite
  case fileChanged
  case destinationExists
  case unsupportedFile
  case inspect(errno: Int32)
  case open(errno: Int32)
  case write(errno: Int32)
  case permissions(errno: Int32)
  case synchronize(errno: Int32)
  case replace(errno: Int32)
  case committedButCannotInspect(errno: Int32)
  case committedButCleanupFailed(errno: Int32)

  var message: String {
    switch self {
    case .invalidPath: return "Cannot write: invalid file path."
    case .invalidByteCount, .invalidChunk, .incompleteWrite: return "Cannot write: incomplete or invalid buffer."
    case .fileChanged: return "Cannot write: file changed on disk. Unsaved edits are retained."
    case .destinationExists: return "Cannot write: destination already exists. Choose a new path."
    case .unsupportedFile: return "Cannot write: use a regular file without symbolic or hard links."
    case .inspect: return "Cannot write: file inspection failed. Unsaved edits are retained."
    case .open: return "Cannot write: check file and directory permissions. Unsaved edits are retained."
    case .write: return "Cannot write: disk write failed. Unsaved edits are retained."
    case .permissions: return "Cannot write: file permissions could not be preserved."
    case .synchronize: return "Cannot write: disk synchronization failed. Unsaved edits are retained."
    case .replace: return "Cannot write: file replacement failed. Unsaved edits are retained."
    case .committedButCannotInspect:
      return "File written, but its new identity could not be read. Reopen before writing again."
    case .committedButCleanupFailed:
      return "File written, but its temporary link could not be removed. Reopen before writing again."
    }
  }
}

/// An explicit save transaction. No target bytes change until commit atomically
/// renames the complete sibling file. Abandoning the owner removes the temporary
/// file. A caller can append bounded chunks over multiple application turns.
///
/// This operation is outside the allocation-free edit/render loop: path strings,
/// their C-string bridges, and error propagation may allocate. No document-sized
/// storage is allocated. Each append accepts at most 1 MiB, with at most eight EINTR retries
/// and at most one successful syscall per byte in the short-write worst case.
/// Syscall latency, including fsync, is outside the CPU work bound.
///
/// Source identity is checked at start and immediately before rename; this
/// catches ordinary external edits/replacements, but is not a cross-process lock.
/// Symlinks and hard links are rejected rather than changing their semantics.
/// Existing-file owner, group, and POSIX permission bits are preserved. Extended
/// attributes and ACLs are not copied by this prototype. Atomic replacement is guaranteed;
/// crash durability of the containing directory is not.
struct DocumentFileWrite: ~Copyable, ~Sendable {
  static let maximumChunkBytes = 1_048_576

  private let path: String
  private let temporaryPath: String
  private let original: FileDescriptor?
  private let temporary: FileDescriptor
  private let expectedIdentity: DocumentFileIdentity?
  private let expectedByteCount: Int
  private let originalStatus: Stat?
  private var committed = false
  private var ownsTemporaryPath = true
  private var failed = false
  private(set) var bytesWritten = 0

  /// A nil identity creates a new destination and refuses any existing entry,
  /// including a dangling symlink. Publication uses atomic link creation so a
  /// competing creator is never overwritten. New files use owner-read/write
  /// permissions subject to umask; the caller validates its input snapshot.
  init(
    _ path: String, expectedIdentity: DocumentFileIdentity?, expectedByteCount: Int
  ) throws(DocumentFileWriteError) {
    guard !path.isEmpty, !path.utf8.contains(0), !path.hasSuffix("/") else { throw .invalidPath }
    guard expectedByteCount >= 0 else { throw .invalidByteCount }
    let status: Stat?
    let original: FileDescriptor?
    if let expectedIdentity {
      let inspected = try Self.inspect(path)
      try Self.validate(inspected, expected: expectedIdentity)
      status = inspected
      original = try Self.open(path, mode: .readWrite, options: [.closeOnExec, .nonBlocking, .noFollow])
    } else {
      try Self.requireAbsent(path)
      status = nil
      original = nil
    }
    var keepOriginal = false
    defer { if !keepOriginal { try? original?.close() } }
    if let original, let expectedIdentity {
      try Self.validate(try Self.inspect(original), expected: expectedIdentity)
    }

    let directory: String
    if let slash = path.lastIndex(of: "/") {
      directory = String(path[...slash])
    } else {
      directory = "./"
    }
    // The exclusive create never truncates a colliding file. Name retries are
    // bounded and only run in the explicit save operation.
    var created: FileDescriptor?
    var temporaryPath = ""
    for _ in 0..<16 {
      temporaryPath = directory + ".slate-write-\(getpid())-\(UInt64.random(in: .min ... .max))"
      do throws(DocumentFileWriteError) {
        created = try Self.open(
          temporaryPath, mode: .writeOnly,
          options: [.closeOnExec, .create, .exclusiveCreate, .noFollow], permissions: .ownerReadWrite)
        break
      } catch {
        if error != .open(errno: EEXIST) { throw error }
      }
    }
    guard let temporary = created else { throw .open(errno: EEXIST) }
    self.path = path
    self.temporaryPath = temporaryPath
    self.original = original
    self.temporary = temporary
    self.expectedIdentity = expectedIdentity
    self.expectedByteCount = expectedByteCount
    originalStatus = status
    keepOriginal = true
  }

  mutating func append(_ bytes: Span<UInt8>) throws(DocumentFileWriteError) {
    precondition(!committed && !failed, "A completed or failed save cannot be reused")
    guard bytes.count <= Self.maximumChunkBytes, bytes.count <= expectedByteCount - bytesWritten else {
      failed = true
      throw .invalidChunk
    }
    var done = 0
    var interruptions = 0
    while done < bytes.count {
      let result: Result<Int, Errno> = bytes.withUnsafeBufferPointer { storage in
        do {
          return .success(
            try unsafe temporary.write(
              UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(storage)[done...]), retryOnInterrupt: false))
        } catch let error as Errno {
          return .failure(error)
        } catch {
          preconditionFailure("FileDescriptor.write only throws Errno")
        }
      }
      switch result {
      case .success(let count):
        guard count > 0 else {
          failed = true
          throw .write(errno: EIO)
        }
        done += count
        bytesWritten += count
      case .failure(let error):
        if error == .interrupted && interruptions < 8 {
          interruptions += 1
          continue
        }
        failed = true
        throw .write(errno: error.rawValue)
      }
    }
  }

  mutating func commit() throws(DocumentFileWriteError) -> DocumentFileIdentity {
    precondition(!committed && !failed, "A completed or failed save cannot be reused")
    // Poison a failed transaction: callers must start a fresh snapshot check and
    // temporary file rather than retrying a possibly partial operation.
    failed = true
    guard bytesWritten == expectedByteCount else { throw .incompleteWrite }
    // Swift System 1.8 has no ownership/mode setters or fsync/rename wrappers.
    if let originalStatus {
      let temporaryStatus = try Self.inspect(temporary)
      if temporaryStatus.userID != originalStatus.userID || temporaryStatus.groupID != originalStatus.groupID {
        guard fchown(temporary.rawValue, originalStatus.userID.rawValue, originalStatus.groupID.rawValue) == 0 else {
          throw .permissions(errno: errno)
        }
      }
      guard fchmod(temporary.rawValue, originalStatus.permissions.rawValue) == 0 else {
        throw .permissions(errno: errno)
      }
    }
    guard fsync(temporary.rawValue) == 0 else { throw .synchronize(errno: errno) }
    if let original, let expectedIdentity {
      try Self.validate(try Self.inspect(original), expected: expectedIdentity)
      try Self.validate(try Self.inspect(path), expected: expectedIdentity)
      let result = temporaryPath.withCString { temporaryName in
        path.withCString { destinationName in unsafe rename(temporaryName, destinationName) }
      }
      guard result == 0 else { throw .replace(errno: errno) }
      committed = true
      ownsTemporaryPath = false
    } else {
      // A hard-link creation is an atomic no-clobber publication on the same
      // filesystem. A separate existence check followed by rename would race.
      let result = temporaryPath.withCString { temporaryName in
        path.withCString { destinationName in unsafe link(temporaryName, destinationName) }
      }
      guard result == 0 else {
        if errno == EEXIST { throw .destinationExists }
        throw .replace(errno: errno)
      }
      committed = true
      guard temporaryPath.withCString({ unsafe unlink($0) }) == 0 else {
        throw .committedButCleanupFailed(errno: errno)
      }
      ownsTemporaryPath = false
    }
    // Rename can update ctime, so inspect only after replacement. The distinct
    // failure below reports that bytes were committed even if fstat fails.
    do throws(DocumentFileWriteError) {
      return Self.identity(try Self.inspect(temporary))
    } catch {
      if case .inspect(let code) = error { throw .committedButCannotInspect(errno: code) }
      preconditionFailure("Descriptor inspection only throws inspect")
    }
  }

  private static func open(
    _ path: String, mode: FileDescriptor.AccessMode, options: FileDescriptor.OpenOptions,
    permissions: FilePermissions? = nil
  ) throws(DocumentFileWriteError) -> FileDescriptor {
    do {
      return try path.withCString {
        try unsafe FileDescriptor.open($0, mode, options: options, permissions: permissions, retryOnInterrupt: false)
      }
    } catch let error as Errno {
      throw .open(errno: error.rawValue)
    } catch {
      preconditionFailure("FileDescriptor.open only throws Errno")
    }
  }

  private static func inspect(_ path: String) throws(DocumentFileWriteError) -> Stat {
    let result: Result<Stat, Errno> = path.withCString { name in
      do throws(Errno) {
        return .success(try unsafe Stat(name, followTargetSymlink: false, retryOnInterrupt: false))
      } catch { return .failure(error) }
    }
    switch result {
    case .success(let status): return status
    case .failure(let error): throw .inspect(errno: error.rawValue)
    }
  }

  private static func inspect(_ descriptor: FileDescriptor) throws(DocumentFileWriteError) -> Stat {
    do { return try Stat(descriptor, retryOnInterrupt: false) } catch { throw .inspect(errno: error.rawValue) }
  }

  private static func requireAbsent(_ path: String) throws(DocumentFileWriteError) {
    do throws(DocumentFileWriteError) {
      _ = try inspect(path)
    } catch {
      if error == .inspect(errno: ENOENT) { return }
      throw error
    }
    throw .destinationExists
  }

  private static func validate(
    _ status: Stat, expected: DocumentFileIdentity
  ) throws(DocumentFileWriteError) {
    guard status.type == .regular else { throw .unsupportedFile }
    guard status.size >= 0, status.size <= Int.max, identity(status) == expected else { throw .fileChanged }
    guard status.linkCount == 1 else { throw .unsupportedFile }
  }

  private static func identity(_ status: Stat) -> DocumentFileIdentity {
    precondition(status.size >= 0 && status.size <= Int.max)
    return .init(
      device: status.deviceID, inode: status.inode, byteCount: Int(status.size),
      modificationSeconds: status.st_mtim.tv_sec, modificationNanoseconds: status.st_mtim.tv_nsec,
      changeSeconds: status.st_ctim.tv_sec, changeNanoseconds: status.st_ctim.tv_nsec)
  }

  deinit {
    try? original?.close()
    try? temporary.close()
    if ownsTemporaryPath { _ = temporaryPath.withCString { unsafe unlink($0) } }
  }
}
