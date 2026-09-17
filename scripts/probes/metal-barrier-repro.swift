// With a concurrent encoder and a barrier before EVERY dispatch, ggml still produces wrong
// output on this driver. That is the claim in the backend's comment. This reduces it to a
// chain: N dispatches, each reading what the previous wrote, memoryBarrier(.buffers) between
// every pair, all inside one MTLDispatchTypeConcurrent encoder. The serial encoder is the
// control; both do exactly the same work.
import Metal
import Foundation

let n = 1 << 16
let bytes = n * 4
let chain = 64
let iters = 40

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
    e.fill(buffer: buf, range: 0..<bytes, value: 0)
    e.endEncoding(); c.commit(); c.waitUntilCompleted()
}

func run(concurrent: Bool, barrier: Bool) -> (Int, Double) {
    var wrong = 0
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iters {
        zero(a)
        let c = q.makeCommandBuffer()!
        let e = concurrent ? c.makeComputeCommandEncoder(dispatchType: .concurrent)!
                           : c.makeComputeCommandEncoder()!
        e.setComputePipelineState(pipe)
        var src = a, dst = b
        for i in 0..<chain {
            if barrier && i > 0 { e.memoryBarrier(scope: .buffers) }
            e.setBuffer(src, offset: 0, index: 0)
            e.setBuffer(dst, offset: 0, index: 1)
            e.dispatchThreadgroups(MTLSize(width: n/256, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            swap(&src, &dst)
        }
        e.endEncoding()
        let bc = c.makeBlitCommandEncoder()!
        bc.copy(from: src, sourceOffset: 0, to: rb, destinationOffset: 0, size: bytes)
        bc.endEncoding()
        c.commit(); c.waitUntilCompleted()
        let out = rb.contents().bindMemory(to: Float.self, capacity: n)
        for i in 0..<n where out[i] != Float(chain) { wrong += 1; break }
    }
    return (wrong, Double(DispatchTime.now().uptimeNanoseconds - t0)/1000.0/Double(iters))
}

for (name, conc, bar) in [("serial encoder, no barrier ", false, false),
                          ("serial encoder, barriers   ", false, true),
                          ("CONCURRENT, barriers       ", true,  true),
                          ("CONCURRENT, no barrier     ", true,  false)] {
    let (w, us) = run(concurrent: conc, barrier: bar)
    print(String(format: "  %@ wrong runs %2d/%d   %8.1f us", name, w, iters, us))
}
