import Foundation

enum DflashPolicy {
    static func autoEligible(isMoE: Bool, ncmoe: Int) -> Bool {
        isMoE && ncmoe > 0
    }

    static func shouldWarn(fractions: [Double]) -> Bool {
        fractions.count(where: { $0 >= 0.95 }) >= 3
    }
}
