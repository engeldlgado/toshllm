// Cross-device MTLSharedEvent latency between two dies of one peer group.
//
// The first version of this probe was wrong: it reused one event across sub-tests with
// non-monotonic values, so a wait for value 1 on an event already at 100400 was satisfied
// instantly and reported as a 6 us "hop". Everything below therefore uses a fresh event per
// direction, values strictly increasing from 1, and one timing definition for every direction.
//
//   swift scripts/probes/peer-event-probe.swift [iters] [devA] [devB]
//
// Timing definition, identical in both directions and taken from Metal's own GPU clock:
//   hop = consumer.GPUStartTime - producer.GPUEndTime
// The consumer is committed and already stalled before the producer is committed, so the
// consumer cannot start until the signal lands. CPU wake-up is reported separately and never
// mixed into the hop.
import Metal
import Foundation

let iters = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 1000
let iA    = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[2])! : 0
let iB    = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 1

let devs = MTLCopyAllDevices()
guard iA < devs.count, iB < devs.count else { print("FAIL: device index"); exit(1) }
let a = devs[iA], b = devs[iB]
guard a.peerGroupID != 0, a.peerGroupID == b.peerGroupID else {
    print("FAIL: MTL\(iA) and MTL\(iB) are not in one peer group"); exit(1)
}
print("MTL\(iA) peerIndex \(a.peerIndex)  <->  MTL\(iB) peerIndex \(b.peerIndex)   group \(a.peerGroupID)")

func stats(_ name: String, _ xs: [Double]) {
    guard !xs.isEmpty else { print("  \(name): no samples"); return }
    let s = xs.sorted()
    func q(_ p: Double) -> Double { s[min(s.count-1, Int(p*Double(s.count)))] }
    let mean = xs.reduce(0,+)/Double(xs.count)
    let sd = (xs.map { ($0-mean)*($0-mean) }.reduce(0,+)/Double(xs.count)).squareRoot()
    print(String(format: "  %-28@ n%5d  min %7.2f  p50 %7.2f  mean %7.2f  p95 %7.2f  p99 %7.2f  sd %6.2f",
                 name as NSString, xs.count, s[0], q(0.50), mean, q(0.95), q(0.99), sd))
}

// One hop. Fresh event, fresh values. Returns (gpu hop us, cpu notify us) or nil if Metal did
// not give usable timestamps for that pair.
func hop(producer pq: MTLCommandQueue, consumer cq: MTLCommandQueue,
         event ev: MTLSharedEvent, value v: UInt64) -> (Double, Double)? {
    let cons = cq.makeCommandBuffer()!
    cons.encodeWaitForEvent(ev, value: v)
    // a blit on nothing still gives the buffer a body so GPUStartTime is meaningful
    let e = cons.makeBlitCommandEncoder()!
    e.endEncoding()
    cons.commit()
    usleep(300)                                   // the consumer is queued and stalled by now

    let prod = pq.makeCommandBuffer()!
    let pe = prod.makeBlitCommandEncoder()!
    pe.endEncoding()
    prod.encodeSignalEvent(ev, value: v)
    let t0 = DispatchTime.now().uptimeNanoseconds
    prod.commit()
    cons.waitUntilCompleted()
    let cpuNotify = Double(DispatchTime.now().uptimeNanoseconds - t0)/1000.0
    prod.waitUntilCompleted()

    guard prod.gpuEndTime > 0, cons.gpuStartTime > 0 else { return nil }
    return ((cons.gpuStartTime - prod.gpuEndTime)*1e6, cpuNotify)
}

let qA = a.makeCommandQueue()!, qB = b.makeCommandQueue()!
// warm both queues so the first samples are not measuring first-use cost
for _ in 0..<20 {
    for q in [qA, qB] { let c = q.makeCommandBuffer()!; c.commit(); c.waitUntilCompleted() }
}

// a fresh event per direction, so no value from one test can satisfy a wait in the other
var evAB = a.makeSharedEvent()!, evBA = b.makeSharedEvent()!
var vAB: UInt64 = 0, vBA: UInt64 = 0
var gAB: [Double] = [], gBA: [Double] = [], cAB: [Double] = [], cBA: [Double] = []

// alternate every iteration so ordering and thermal drift hit both directions equally
for i in 0..<(2*iters) {
    let forward = (i % 2 == 0)
    if forward {
        vAB += 1
        if let (g, c) = hop(producer: qA, consumer: qB, event: evAB, value: vAB) { gAB.append(g); cAB.append(c) }
    } else {
        vBA += 1
        if let (g, c) = hop(producer: qB, consumer: qA, event: evBA, value: vBA) { gBA.append(g); cBA.append(c) }
    }
}
print("alternating, fresh event per direction:")
stats("MTL\(iA) -> MTL\(iB)  GPU hop", gAB)
stats("MTL\(iB) -> MTL\(iA)  GPU hop", gBA)
stats("MTL\(iA) -> MTL\(iB)  CPU notify", cAB)
stats("MTL\(iB) -> MTL\(iA)  CPU notify", cBA)

// swap which physical die plays producer first, with brand new queues and events, to separate
// physical direction from test order and from queue creation order
let qA2 = a.makeCommandQueue()!, qB2 = b.makeCommandQueue()!
let evBA2 = b.makeSharedEvent()!, evAB2 = a.makeSharedEvent()!
var v1: UInt64 = 0, v2: UInt64 = 0
var rBA: [Double] = [], rAB: [Double] = []
for i in 0..<(2*iters) {
    if i % 2 == 0 {
        v1 += 1
        if let (g, _) = hop(producer: qB2, consumer: qA2, event: evBA2, value: v1) { rBA.append(g) }
    } else {
        v2 += 1
        if let (g, _) = hop(producer: qA2, consumer: qB2, event: evAB2, value: v2) { rAB.append(g) }
    }
}
print("reversed order, new queues and events:")
stats("MTL\(iB) -> MTL\(iA)  GPU hop", rBA)
stats("MTL\(iA) -> MTL\(iB)  GPU hop", rAB)
