// Scalar form only, the one shape that produced a believable fp32 number (70.5% of the
// datasheet peak). Eight independent dependency chains per thread, operand changed every
// iteration, fast math off. Anything above the peak means the test broke again.
import Metal
import Foundation
let threads = 1 << 21, inner = 4096, iters = 10
let peak = 6608.0

func mk(_ name: String, _ ty: String, _ a0: String, _ c0: String, _ b0: String,
        _ op: String, _ bump: String, _ cast: String) -> String {
    var s = "kernel void \(name)(device float * o [[buffer(0)]], constant uint & n [[buffer(1)]], uint t [[thread_position_in_grid]]) {\n"
    s += "  \(ty) b = \(b0);\n"
    for i in 0..<8 { s += "  \(ty) a\(i) = \(a0)\(i); \(ty) c\(i) = \(c0)\(i);\n" }
    s += "  for (uint k = 0; k < n; ++k) {\n"
    for i in 0..<8 { s += "    c\(i) = " + op.replacingOccurrences(of: "A", with: "a\(i)").replacingOccurrences(of: "C", with: "c\(i)") + ";\n" }
    s += "    b += \(bump);\n  }\n  o[t] = \(cast)(" + (0..<8).map { "c\($0)" }.joined(separator: "+") + ");\n}\n"
    return s
}
let src = "#include <metal_stdlib>\nusing namespace metal;\n"
  + mk("f32","float","1.0000","float(t)*1e-6f + ","float(t)*1e-7f","fma(A, b, C)","1e-9f","float")
  + mk("i32","int","3 + ","int(t & 7) + ","int(t & 15)","A*b + C","1","float")
  + mk("m24","int","3 + ","int(t & 7) + ","int(t & 15)","mad24(A, b, C)","1","float")

let d = MTLCopyAllDevices().first!
print("device: \(d.name)   pico fp32 = \(Int(peak)) GMAC/s")
let q = d.makeCommandQueue()!
let o = d.makeBuffer(length: threads*4, options: .storageModePrivate)!
let opts = MTLCompileOptions()
if #available(macOS 15.0, *) { opts.mathMode = .safe }
let lib = try! d.makeLibrary(source: src, options: opts)
var n = UInt32(inner)
var base = 0.0
for name in ["f32", "i32", "m24"] {
    let pipe = try! d.makeComputePipelineState(function: lib.makeFunction(name: name)!)
    func once() {
        let c = q.makeCommandBuffer()!, e = c.makeComputeCommandEncoder()!
        e.setComputePipelineState(pipe); e.setBuffer(o, offset: 0, index: 0); e.setBytes(&n, length: 4, index: 1)
        e.dispatchThreadgroups(MTLSize(width: threads/256, height: 1, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        e.endEncoding(); c.commit(); c.waitUntilCompleted()
    }
    for _ in 0..<3 { once() }
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iters { once() }
    let sec = Double(DispatchTime.now().uptimeNanoseconds - t0)/1e9/Double(iters)
    let g = Double(threads) * Double(inner) * 8.0 / sec / 1e9
    if name == "f32" { base = g }
    print(String(format: "  %-4@ %8.1f GMAC/s  %5.1f%% del pico  x%.2f sobre f32",
                 name as NSString, g, 100*g/peak, g/base))
}
