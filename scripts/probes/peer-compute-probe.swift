// Can a compute kernel read a buffer that lives on another GPU of the same peer group?
// Metal documents remote buffer views for blit copies; if a shader can read one directly, the
// tensor-split allreduce can fuse its copy and its add into a single kernel.
//
//   swift scripts/probes/peer-compute-probe.swift          two GPUs of one peer group (W6800X/Vega II Duo)
//   swift scripts/probes/peer-compute-probe.swift --self   one GPU, checks the harness itself
//
// Prints PASS or FAIL and touches nothing else.

import Metal
import Foundation

let selfMode = CommandLine.arguments.contains("--self")
let n = 1 << 16
let bytes = n * MemoryLayout<Float>.size

let source = """
#include <metal_stdlib>
using namespace metal;
kernel void add_inplace(device float * dst [[buffer(0)]],
                        device const float * src [[buffer(1)]],
                        uint tid [[thread_position_in_grid]]) {
    dst[tid] += src[tid];
}
"""

// The width a threadgroup actually executes at, straight from the pipeline. Vega reports 64.
func simdWidth(_ dev: MTLDevice) -> Int? {
    let src = "#include <metal_stdlib>\nkernel void probe(device float * x [[buffer(0)]], uint t [[thread_position_in_grid]]) { x[t] = 0; }"
    guard let lib = try? dev.makeLibrary(source: src, options: nil),
          let fn = lib.makeFunction(name: "probe"),
          let pipe = try? dev.makeComputePipelineState(function: fn) else { return nil }
    return pipe.threadExecutionWidth
}

let devices = MTLCopyAllDevices()
for (i, d) in devices.enumerated() {
    let vram = Double(d.recommendedMaxWorkingSetSize) / (1024*1024*1024)
    print(String(format: "device %d: %@ peerGroupID=%llu peerIndex=%u peerCount=%u vram=%.2fGiB unified=%@",
                 i, d.name, d.peerGroupID, d.peerIndex, d.peerCount, vram,
                 d.hasUnifiedMemory ? "yes" : "no"))
    print("  maxThreadsPerThreadgroup=\(d.maxThreadsPerThreadgroup.width) simdWidth=\(simdWidth(d).map(String.init) ?? "?")")
}

var devA: MTLDevice?
var devB: MTLDevice?
if selfMode {
    devA = devices.first
    devB = devices.first
} else {
    outer: for a in devices {
        guard a.peerGroupID != 0 else { continue }
        for b in devices where b !== a && b.peerGroupID == a.peerGroupID {
            devA = a; devB = b
            break outer
        }
    }
}

guard let a = devA, let b = devB else {
    print("FAIL: no two devices in a peer group (run with --self to check the harness)")
    exit(1)
}
print("source GPU: \(a.name)\ntarget GPU: \(b.name)")

// Both buffers private, which is what a remote view requires.
func fill(_ dev: MTLDevice, _ queue: MTLCommandQueue, _ dst: MTLBuffer, _ value: Float) {
    var host = [Float](repeating: value, count: n)
    let stage = dev.makeBuffer(bytes: &host, length: bytes, options: .storageModeShared)!
    let cmd = queue.makeCommandBuffer()!
    let blit = cmd.makeBlitCommandEncoder()!
    blit.copy(from: stage, sourceOffset: 0, to: dst, destinationOffset: 0, size: bytes)
    blit.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
}

// dst = dst + view(src), run on the destination GPU. Returns the count of wrong values.
func remoteAdd(from src: MTLDevice, to dst: MTLDevice,
               _ qSrc: MTLCommandQueue, _ qDst: MTLCommandQueue, label: String) -> Bool {
    let bufSrc = src.makeBuffer(length: bytes, options: .storageModePrivate)!
    let bufDst = dst.makeBuffer(length: bytes, options: .storageModePrivate)!
    fill(src, qSrc, bufSrc, 1.0)
    fill(dst, qDst, bufDst, 2.0)

    var remote: MTLBuffer?
    if selfMode {
        remote = bufSrc
    } else {
        remote = bufSrc.makeRemoteBufferView(dst)
        if remote == nil {
            print("FAIL \(label): newRemoteBufferViewForDevice returned nil")
            return false
        }
        print("\(label): remote view created, remoteStorageBuffer=\(remote!.remoteStorageBuffer != nil)")
    }

    let lib = try! dst.makeLibrary(source: source, options: nil)
    let pipe = try! dst.makeComputePipelineState(function: lib.makeFunction(name: "add_inplace")!)

    let cmd = qDst.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipe)
    enc.setBuffer(bufDst, offset: 0, index: 0)
    enc.setBuffer(remote!, offset: 0, index: 1)
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    if let error = cmd.error {
        print("FAIL \(label): command buffer error: \(error)")
        return false
    }

    let readback = dst.makeBuffer(length: bytes, options: .storageModeShared)!
    let cmdR = qDst.makeCommandBuffer()!
    let blit = cmdR.makeBlitCommandEncoder()!
    blit.copy(from: bufDst, sourceOffset: 0, to: readback, destinationOffset: 0, size: bytes)
    blit.endEncoding()
    cmdR.commit()
    cmdR.waitUntilCompleted()

    let out = readback.contents().bindMemory(to: Float.self, capacity: n)
    var bad = 0
    for i in 0..<n where out[i] != 3.0 {
        if bad < 4 { print("  [\(i)] = \(out[i]), expected 3.0") }
        bad += 1
    }
    if bad != 0 {
        print("FAIL \(label): \(bad)/\(n) values wrong")
        return false
    }
    print("PASS \(label): the kernel read the \(selfMode ? "local" : "remote") buffer, \(n) values correct")
    return true
}

let queueA = a.makeCommandQueue()!
let queueB = b.makeCommandQueue()!

// Both directions: a one-way view says nothing about the return leg of an allreduce.
let okAB = remoteAdd(from: a, to: b, queueA, queueB, label: "A->B")
let okBA = selfMode ? true : remoteAdd(from: b, to: a, queueB, queueA, label: "B->A")

exit(okAB && okBA ? 0 : 1)
