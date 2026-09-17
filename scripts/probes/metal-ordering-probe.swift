// The barrier inside a concurrent encoder is ignored on this driver. The other way to order
// two dispatches is an encoder boundary. If that holds, a concurrency-safe design is possible:
// group mutually independent nodes into one concurrent encoder and end it at every dependency,
// instead of relying on memoryBarrier.
import Metal
import Foundation

let n = 1 << 16, bytes = n * 4, chain = 64, iters = 40
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void step(device const float * in [[buffer(0)]], device float * out [[buffer(1)]],
                 uint t [[thread_position_in_grid]]) { out[t] = in[t] + 1.0f; }
"""
let d = MTLCopyAllDevices().first!
print("device: \(d.name)")
let q = d.makeCommandQueue()!
let a = d.makeBuffer(length: bytes, options: .storageModePrivate)!
let b = d.makeBuffer(length: bytes, options: .storageModePrivate)!
let rb = d.makeBuffer(length: bytes, options: .storageModeShared)!
let pipe = try! d.makeComputePipelineState(function: d.makeLibrary(source: src, options: nil).makeFunction(name: "step")!)
func zero(_ buf: MTLBuffer) {
    let c = q.makeCommandBuffer()!, e = c.makeBlitCommandEncoder()!
    e.fill(buffer: buf, range: 0..<bytes, value: 0); e.endEncoding(); c.commit(); c.waitUntilCompleted()
}
// mode: "serial" one serial encoder; "barrier" one concurrent encoder + barriers;
//       "encoder" a NEW concurrent encoder per link
func run(_ mode: String) -> (Int, Double) {
    var wrong = 0
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iters {
        zero(a)
        if mode == "cmdbuf" {
            // one command buffer per link, each with its own concurrent encoder
            var s = a, dst = b
            var last: MTLCommandBuffer! = nil
            for _ in 0..<chain {
                let cc = q.makeCommandBuffer()!
                let ee = cc.makeComputeCommandEncoder(dispatchType: .concurrent)!
                ee.setComputePipelineState(pipe)
                ee.setBuffer(s, offset: 0, index: 0); ee.setBuffer(dst, offset: 0, index: 1)
                ee.dispatchThreadgroups(MTLSize(width: n/256, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                ee.endEncoding(); cc.commit(); last = cc
                swap(&s, &dst)
            }
            let cf = q.makeCommandBuffer()!
            let bf = cf.makeBlitCommandEncoder()!
            bf.copy(from: s, sourceOffset: 0, to: rb, destinationOffset: 0, size: bytes)
            bf.endEncoding(); cf.commit(); cf.waitUntilCompleted()
            _ = last
            let out = rb.contents().bindMemory(to: Float.self, capacity: n)
            for i in 0..<n where out[i] != Float(chain) { wrong += 1; break }
            continue
        }
        let c = q.makeCommandBuffer()!
        var s = a, dst = b
        var e: MTLComputeCommandEncoder? = nil
        if mode != "encoder" {
            e = mode == "serial" ? c.makeComputeCommandEncoder()!
                                 : c.makeComputeCommandEncoder(dispatchType: .concurrent)!
            e!.setComputePipelineState(pipe)
        }
        for i in 0..<chain {
            if mode == "encoder" {
                e = c.makeComputeCommandEncoder(dispatchType: .concurrent)!
                e!.setComputePipelineState(pipe)
            } else if mode == "barrier" && i > 0 {
                e!.memoryBarrier(scope: .buffers)
            }
            e!.setBuffer(s, offset: 0, index: 0); e!.setBuffer(dst, offset: 0, index: 1)
            e!.dispatchThreadgroups(MTLSize(width: n/256, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            if mode == "encoder" { e!.endEncoding() }
            swap(&s, &dst)
        }
        if mode != "encoder" { e!.endEncoding() }
        let bc = c.makeBlitCommandEncoder()!
        bc.copy(from: s, sourceOffset: 0, to: rb, destinationOffset: 0, size: bytes)
        bc.endEncoding(); c.commit(); c.waitUntilCompleted()
        let out = rb.contents().bindMemory(to: Float.self, capacity: n)
        for i in 0..<n where out[i] != Float(chain) { wrong += 1; break }
    }
    return (wrong, Double(DispatchTime.now().uptimeNanoseconds - t0)/1000.0/Double(iters))
}
for m in ["serial", "barrier", "encoder", "cmdbuf"] {
    let (w, us) = run(m)
    print(String(format: "  %-9@ wrong %2d/%d   %8.1f us", m as NSString, w, iters, us))
}
