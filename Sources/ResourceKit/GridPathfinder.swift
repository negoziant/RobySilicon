import Foundation

public struct GridPathfinder {
    public let width: Int
    public let height: Int
    public let closedVerts: Set<GridCell>
    public let closedDirs: [GridCell: Set<Int>]
    public let allowedDirs: [Int]

    public struct GridCell: Hashable {
        public let x: Int
        public let y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
    }

    public init(config: SceneConfig, characterClosedDirs: [GridDirection] = [],
                dynamicOpened: Set<GridCell> = [], dynamicClosed: Set<GridCell> = [],
                objectClosedVerts: [(Int, Int)] = [], objectClosedDirs: [GridDirection] = [],
                allowedDirs: [Int] = GridPathfinder.moveDirs) {
        self.width = config.gridLength.0
        self.height = config.gridLength.1
        self.allowedDirs = allowedDirs

        var cv = Set<GridCell>()
        for v in config.closedVerts {
            cv.insert(GridCell(x: v.0, y: v.1))
        }
        // Активные объекты закрывают свои клетки (ClosedVert из OB, дом/пальма)
        for v in objectClosedVerts {
            cv.insert(GridCell(x: v.0, y: v.1))
        }
        cv.subtract(dynamicOpened)
        cv.formUnion(dynamicClosed)
        self.closedVerts = cv

        var cd: [GridCell: Set<Int>] = [:]
        for d in config.closedDirs + characterClosedDirs + objectClosedDirs {
            let cell = GridCell(x: d.x, y: d.y)
            cd[cell, default: []].insert(d.dir)
        }
        self.closedDirs = cd
    }

    // Numpad direction → (dx, dy)
    public static func delta(forDirection dir: Int) -> (Int, Int) {
        switch dir {
        case 1: return (-1, 1)
        case 2: return (0, 1)
        case 3: return (1, 1)
        case 4: return (-1, 0)
        case 6: return (1, 0)
        case 7: return (-1, -1)
        case 8: return (0, -1)
        case 9: return (1, -1)
        default: return (0, 0)
        }
    }

    // (dx, dy) → numpad direction
    public static func direction(dx: Int, dy: Int) -> Int {
        switch (dx.clamped(-1, 1), dy.clamped(-1, 1)) {
        case (-1, 1): return 1
        case (0, 1): return 2
        case (1, 1): return 3
        case (-1, 0): return 4
        case (1, 0): return 6
        case (-1, -1): return 7
        case (0, -1): return 8
        case (1, -1): return 9
        default: return 5
        }
    }

    public static let moveDirs = [1, 2, 3, 4, 6, 7, 8, 9]

    public func findPath(from start: GridCell, to target: GridCell) -> [Int]? {
        if start == target { return [] }
        if closedVerts.contains(target) { return nil }

        var visited = Set<GridCell>()
        visited.insert(start)
        var queue: [(cell: GridCell, path: [Int])] = [(start, [])]
        var head = 0

        while head < queue.count {
            let (current, path) = queue[head]
            head += 1

            for dir in allowedDirs {
                if let blocked = closedDirs[current], blocked.contains(dir) { continue }

                let (dx, dy) = Self.delta(forDirection: dir)
                let next = GridCell(x: current.x + dx, y: current.y + dy)

                guard next.x >= 0, next.x < width, next.y >= 0, next.y < height else { continue }
                guard !closedVerts.contains(next) else { continue }
                guard !visited.contains(next) else { continue }

                let newPath = path + [dir]
                if next == target { return newPath }

                visited.insert(next)
                queue.append((next, newPath))
            }
        }

        return nil
    }

    public func findNearestReachable(from start: GridCell, to target: GridCell) -> (cell: GridCell, path: [Int])? {
        if let path = findPath(from: start, to: target) { return (target, path) }

        var best: (cell: GridCell, path: [Int])? = nil
        var bestDist = Int.max

        var visited = Set<GridCell>()
        visited.insert(start)
        var queue: [(cell: GridCell, path: [Int])] = [(start, [])]
        var head = 0

        while head < queue.count {
            let (current, path) = queue[head]
            head += 1

            let dist = abs(current.x - target.x) + abs(current.y - target.y)
            if dist < bestDist {
                bestDist = dist
                best = (current, path)
            }

            for dir in allowedDirs {
                if let blocked = closedDirs[current], blocked.contains(dir) { continue }

                let (dx, dy) = Self.delta(forDirection: dir)
                let next = GridCell(x: current.x + dx, y: current.y + dy)

                guard next.x >= 0, next.x < width, next.y >= 0, next.y < height else { continue }
                guard !closedVerts.contains(next) else { continue }
                guard !visited.contains(next) else { continue }

                visited.insert(next)
                queue.append((next, path + [dir]))
            }
        }

        return best
    }
}

extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int {
        Swift.min(Swift.max(self, low), high)
    }
}
