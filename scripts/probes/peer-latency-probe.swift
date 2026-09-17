// What one TP2 exchange is actually made of. The collective costs ~140 us per crossing while
// the crossing itself is 21 KB, so the bytes are not the cost. This times the pieces on their
// own: command buffer turnaround, cross-device event hand-off, and the two kernels.
//
//   swift scripts/probes/peer-latency-probe.swift [bytes]
//
// Prints microseconds per operation. Touches nothing else.

import Metal
import Foundation

let bytes = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 21279
let n = bytes / MemoryLayout<Float>.size
let iters = 300

let source = """
#include <metal_stdlib>
using namespace metal;
kernel void add_inplace(device float * dst [[buffer(0)]],
                        device const float * src [[buffer(1)]],
                        uint tid [[thread_position_in_grid]]) {
    dst[tid] += src[tid];
}
kernel void copy_out(device float * dst [[buffer(0)]],
                     device const float * src [[buffer(1)]],
                     uint tid [[thread_position_in_grid]]) {
    dst[tid] = src[tid];
}
"""

let devices = MTLCopyAllDevices()
var devA: MTLDevice?, devB: MTLDevice?
outer: for a in devices where a.peerGroupID != 0 {
    for b in devices where b !== a && b.peerGroupID == a.peerGroupID { devA = a; devB = b; break outer }
}
guard let a = devA, let b = devB else { print("FAIL: no peer pair"); exit(1) }

let qA = a.makeCommandQueue()!, qB = b.makeCommandQueue()!
let bufA = a.makeBuffer(length: bytes, options: .storageModePrivate)!
let bufB = b.makeBuffer(length: bytes, options: .storageModePrivate)!
let localA = a.makeBuffer(length: bytes, options: .storageModePrivate)!
guard let viewOfB = bufB.makeRemoteBufferView(a) else { print("FAIL: no remote view"); exit(1) }

// one host block wrapped on both devices, the shape the staged path uses
let host = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16384)
let wrapA = a.makeBuffer(bytesNoCopy: host, length: bytes, options: .storageModeShared, deallocator: nil)!
let wrapB = b.makeBuffer(bytesNoCopy: host, length: bytes, options: .storageModeShared, deallocator: nil)!

let libA = try! a.makeLibrary(source: source, options: nil)
let addA  = try! a.makeComputePipelineState(function: libA.makeFunction(name: "add_inplace")!)
let copyA = try! a.makeComputePipelineState(function: libA.makeFunction(name: "copy_out")!)

func us(_ block: () -> Void) -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    block()
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000.0 / Double(iters)
}

func report(_ name: String, _ v: Double) {
    print(String(format: "  %-42s %8.2f us", (name as NSString).utf8String!, v))
}

func kernelRun(_ pipe: MTLComputePipelineState, _ dst: MTLBuffer, _ src: MTLBuffer) -> Double {
    return us {
        for _ in 0..<iters {
            let cmd = qA.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pipe)
            enc.setBuffer(dst, offset: 0, index: 0)
            enc.setBuffer(src, offset: 0, index: 1)
            enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        }
    }
}

print("payload \(bytes) B, \(iters) iterations")

report("empty command buffer, submit to complete", us {
    for _ in 0..<iters { let c = qA.makeCommandBuffer()!; c.commit(); c.waitUntilCompleted() }
})

report("blit local->local", us {
    for _ in 0..<iters {
        let c = qA.makeCommandBuffer()!
        let e = c.makeBlitCommandEncoder()!
        e.copy(from: localA, sourceOffset: 0, to: bufA, destinationOffset: 0, size: bytes)
        e.endEncoding(); c.commit(); c.waitUntilCompleted()
    }
})

report("kernel add, both operands local", kernelRun(addA, bufA, localA))
report("kernel add, src is a remote view", kernelRun(addA, bufA, viewOfB))
report("kernel copy, dst is a remote view", kernelRun(copyA, viewOfB, localA))
report("kernel add, src is the host block", kernelRun(addA, bufA, wrapA))

// the sync itself: A signals, B waits and signals back, A waits
let evAB = a.makeSharedEvent()!, evBA = b.makeSharedEvent()!
report("cross-device event ping-pong (2 hops)", us {
    for i in 1...iters {
        let v = UInt64(i)
        let cB = qB.makeCommandBuffer()!
        cB.encodeWaitForEvent(evAB, value: v)
        cB.encodeSignalEvent(evBA, value: v)
        cB.commit()
        let cA = qA.makeCommandBuffer()!
        cA.encodeSignalEvent(evAB, value: v)
        cA.encodeWaitForEvent(evBA, value: v)
        cA.commit()
        cA.waitUntilCompleted()
        cB.waitUntilCompleted()
    }
})

// the whole exchange as the engine encodes it, both cards
let evR = a.makeSharedEvent()!, evR2 = b.makeSharedEvent()!
guard let viewOfA = bufA.makeRemoteBufferView(b) else { print("FAIL: no reverse view"); exit(1) }
let libB = try! b.makeLibrary(source: source, options: nil)
let addB = try! b.makeComputePipelineState(function: libB.makeFunction(name: "add_inplace")!)
report("full symmetric exchange, both cards", us {
    for i in 1...iters {
        let v = UInt64(i)
        let cA = qA.makeCommandBuffer()!
        cA.encodeSignalEvent(evR, value: v)
        cA.encodeWaitForEvent(evR2, value: v)
        let eA = cA.makeComputeCommandEncoder()!
        eA.setComputePipelineState(addA)
        eA.setBuffer(bufA, offset: 0, index: 0); eA.setBuffer(viewOfB, offset: 0, index: 1)
        eA.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        eA.endEncoding(); cA.commit()

        let cB = qB.makeCommandBuffer()!
        cB.encodeSignalEvent(evR2, value: v)
        cB.encodeWaitForEvent(evR, value: v)
        let eB = cB.makeComputeCommandEncoder()!
        eB.setComputePipelineState(addB)
        eB.setBuffer(bufB, offset: 0, index: 0); eB.setBuffer(viewOfA, offset: 0, index: 1)
        eB.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                           threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        eB.endEncoding(); cB.commit()

        cA.waitUntilCompleted(); cB.waitUntilCompleted()
    }
})
