import Foundation

public struct WalkingAnimationMap {
    private var lookup: [Int: String] = [:]

    public init(animationList: AnimationList) {
        for (_, name) in animationList.entries.enumerated() {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 4 else { continue }
            let suffix = clean.suffix(2)
            guard let fromDir = Int(String(suffix.first!)),
                  let toDir = Int(String(suffix.last!)) else { continue }
            let key = fromDir * 10 + toDir
            lookup[key] = clean
        }
    }

    public func fsName(from fromDir: Int, to toDir: Int) -> String? {
        lookup[fromDir * 10 + toDir]
    }

    public var count: Int { lookup.count }
}
