// The blit engine refuses a remote buffer view as a destination:
//   amdMtl_CopyFromBufferToBuffer: "RemoteView supports read-only operation and cannot be
//   used as Destination!"
// That assertion is in the blit path. A compute kernel is a different one, and reading
// through a view already works (peer-compute-probe), so this asks whether a shader can
// store into a peer's VRAM. A push would beat a pull: a fabric write is posted, a read stalls.
//
//   swift scripts/probes/peer-write-probe.swift <mode>
//     kernel-write   a shader on A stores into a view of B's buffer
//     kernel-atomic  the same through atomic stores
//     blit-copy      a blit on A copies into the view      (expected to trap)
//     blit-fill      a blit on A fills the view            (expected to trap)
//
// Each mode runs in its own process because a failed one takes the process with it.

import Metal
import Foundation

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "kernel-write"
let n = 1 << 14
let bytes = n * MemoryLayout<Float>.size

let source = """
#include <metal_stdlib>
using namespace metal;
kernel void store_plain(device float * dst [[buffer(0)]],
                        uint tid [[thread_position_in_grid]]) {
    dst[tid] = 7.0f;
}
kernel void store_atomic(device atomic_uint * dst [[buffer(0)]],
                         uint tid [[thread_position_in_grid]]) {
    atomic_store_explicit(&dst[tid], 0x40E00000u, memory_order_relaxed); // 7.0f
}
"""

let devices = MTLCopyAllDevices()
var devA: MTLDevice?, devB: MTLDevice?
outer: for a in devices where a.peerGroupID != 0 {
    for b in devices where b !== a && b.peerGroupID == a.peerGroupID {
        devA = a; devB = b
        break outer
    }
}
guard let a = devA, let b = devB else {
    print("FAIL: no two devices in a peer group")
    exit(1)
}

let qA = a.makeCommandQueue()!
let qB = b.makeCommandQueue()!

// B's buffer, the one A wants to write into. Private, which is what a view requires.
let bufB = b.makeBuffer(length: bytes, options: .storageModePrivate)!
let srcA = a.makeBuffer(length: bytes, options: .storageModePrivate)!

// seed B with 1.0 so an unwritten result is distinguishable from a wrong one
do {
    var host = [Float](repeating: 1.0, count: n)
    let stage = b.makeBuffer(bytes: &host, length: bytes, options: .storageModeShared)!
    let cmd = qB.makeCommandBuffer()!
    let blit = cmd.makeBlitCommandEncoder()!
    blit.copy(from: stage, sourceOffset: 0, to: bufB, destinationOffset: 0, size: bytes)
    blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
}
// seed A's source with 7.0 for the blit modes
do {
    var host = [Float](repeating: 7.0, count: n)
    let stage = a.makeBuffer(bytes: &host, length: bytes, options: .storageModeShared)!
    let cmd = qA.makeCommandBuffer()!
    let blit = cmd.makeBlitCommandEncoder()!
    blit.copy(from: stage, sourceOffset: 0, to: srcA, destinationOffset: 0, size: bytes)
    blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
}

guard let view = bufB.makeRemoteBufferView(a) else {
    print("FAIL: newRemoteBufferViewForDevice returned nil")
    exit(1)
}
print("mode=\(mode) view ok, remoteStorageBuffer=\(view.remoteStorageBuffer != nil)")

let cmd = qA.makeCommandBuffer()!
switch mode {
case "kernel-write", "kernel-atomic":
    let lib = try! a.makeLibrary(source: source, options: nil)
    let name = mode == "kernel-write" ? "store_plain" : "store_atomic"
    let pipe = try! a.makeComputePipelineState(function: lib.makeFunction(name: name)!)
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipe)
    enc.setBuffer(view, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding()
case "blit-copy":
    let enc = cmd.makeBlitCommandEncoder()!
    enc.copy(from: srcA, sourceOffset: 0, to: view, destinationOffset: 0, size: bytes)
    enc.endEncoding()
case "blit-fill":
    let enc = cmd.makeBlitCommandEncoder()!
    enc.fill(buffer: view, range: 0..<bytes, value: 0x40)
    enc.endEncoding()
default:
    print("FAIL: unknown mode"); exit(1)
}
cmd.commit()
cmd.waitUntilCompleted()

if let error = cmd.error {
    print("FAIL: command buffer error: \(error)")
    exit(1)
}

// read B's own buffer back on B: the question is whether A's store is visible there
let readback = b.makeBuffer(length: bytes, options: .storageModeShared)!
let cmdR = qB.makeCommandBuffer()!
let blit = cmdR.makeBlitCommandEncoder()!
blit.copy(from: bufB, sourceOffset: 0, to: readback, destinationOffset: 0, size: bytes)
blit.endEncoding(); cmdR.commit(); cmdR.waitUntilCompleted()

let out = readback.contents().bindMemory(to: Float.self, capacity: n)
let expected: Float = mode == "blit-fill" ? Float(bitPattern: 0x40404040) : 7.0
var bad = 0
for i in 0..<n where out[i] != expected {
    if bad < 4 { print("  [\(i)] = \(out[i]), expected \(expected)") }
    bad += 1
}

if bad == 0 {
    print("PASS \(mode): A wrote \(n) values into B's VRAM and B sees them")
} else {
    print("FAIL \(mode): \(bad)/\(n) values wrong (unwritten reads back as 1.0)")
    exit(1)
}
