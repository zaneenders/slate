import BasicContainers
import CIOTestSupport
import Foundation
import Testing

@testable import SlateTerminal

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

@Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
func bufferedOutputAllocationAtMaximumCapacityAndExhaustion() throws {
  try #require(cli_test_prepare_allocation_counter() != 0)
  let capacity = 64 * 1_048_576
  let buffer = OutputBuffer(capacity: capacity)
  let output = Output(buffer: buffer)
  let chunk = RigidArray<UInt8>(repeating: 127, count: 65_536)
  var spare = RigidArray<UInt8>(repeating: 0, count: capacity)
  try fillOutput(output: output, capacity: capacity, chunk: chunk)
  rejectOutput(output: output, chunk: chunk)
  _ = buffer.take(into: &spare)
  cli_test_begin_allocation_count()
  let count: Int
  do throws(IOError) {
    try fillOutput(output: output, capacity: capacity, chunk: chunk)
    count = buffer.take(into: &spare)
  } catch {
    _ = cli_test_end_allocation_count()
    throw error
  }
  let calls = cli_test_end_allocation_count()
  try fillOutput(output: output, capacity: capacity, chunk: chunk)
  cli_test_begin_allocation_count()
  for _ in 0..<100 { rejectOutput(output: output, chunk: chunk) }
  let rejectionCalls = cli_test_end_allocation_count()
  #expect(count == capacity && buffer.take(into: &spare) == capacity)
  #expect(spare[capacity - 1] == 127)
  #expect(calls == 0)
  // Swift 6.4.2 may allocate one error box when a typed throw crosses the module boundary.
  #expect(rejectionCalls <= 100)
  print(
    "Buffered output: \(capacity) bytes plus equal spare, \(calls) steady allocation calls; \(rejectionCalls) error allocations / 100 rejections"
  )
}

private func fillOutput(output: borrowing Output, capacity: Int, chunk: borrowing RigidArray<UInt8>) throws(IOError) {
  for _ in 0..<(capacity / chunk.count) { try output.writeAll(chunk.span) }
}

private func rejectOutput(output: borrowing Output, chunk: borrowing RigidArray<UInt8>) {
  do throws(IOError) {
    try output.writeAll(chunk.span)
    preconditionFailure("A full output buffer accepted more bytes")
  } catch { precondition(error == .write(errno: ENOBUFS, bytesWritten: 0)) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_ALLOCATION_PROBE"] == "1"))
func nativeBackpressureAllocationUsesResultValues() throws {
  try #require(cli_test_prepare_allocation_counter() != 0)
  var descriptors: InlineArray<2, Int32> = [-1, -1]
  var storage = descriptors.mutableSpan
  try #require(storage.withUnsafeMutableBufferPointer { unsafe pipe($0.baseAddress!) } == 0)
  defer {
    _ = close(descriptors[0])
    _ = close(descriptors[1])
  }
  try #require(fcntl(descriptors[1], F_SETFL, O_NONBLOCK) == 0)
  let output = try Output(fileDescriptor: descriptors[1])
  let chunk = RigidArray<UInt8>(repeating: 0, count: 65_536)
  var full = false
  for _ in 0..<1_024 {
    if case .failure(.write(EAGAIN, _)) = output.writeAvailable(chunk.span) {
      full = true
      break
    }
  }
  try #require(full)
  _ = output.writeAvailable(chunk.span)
  cli_test_begin_allocation_count()
  var rejections = 0
  for _ in 0..<1_000 {
    if case .failure(.write(EAGAIN, _)) = output.writeAvailable(chunk.span) { rejections += 1 }
  }
  let calls = cli_test_end_allocation_count()
  #expect(rejections == 1_000)
  #expect(calls == 0)
  print("Native backpressure: \(rejections) retries, \(calls) allocation calls")
}
