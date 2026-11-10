import Foundation

/// Finds foods that are probably the same thing entered twice (FR-26, backlog #41).
public enum FoodDuplicates {
    public struct Candidate: Hashable, Sendable {
        public var id: String
        public var name: String
        public var brand: String?
        public var barcodes: [String]

        public init(id: String, name: String, brand: String?, barcodes: [String]) {
            self.id = id
            self.name = name
            self.brand = brand
            self.barcodes = barcodes
        }
    }

    /// Lower-cased, diacritics removed, punctuation and repeated spaces collapsed: "Čokolada  Milka!" → "cokolada milka".
    public static func normalize(_ text: String?) -> String {
        guard let text else { return "" }
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"),
        )
        let words = folded.lowercased().split { !($0.isLetter || $0.isNumber) }
        return words.joined(separator: " ")
    }

    /// Name + brand as one comparison key; empty when the name is empty.
    public static func key(name: String, brand: String?) -> String {
        let name = normalize(name)
        guard !name.isEmpty else { return "" }
        return name + "|" + normalize(brand)
    }

    /// Groups of ids that share a barcode or the same normalized name + brand (transitively), each with two or more
    /// foods, in the order of their first member in `foods`.
    public static func groups(_ foods: [Candidate]) -> [[String]] {
        var parent = Array(foods.indices)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root {
                root = parent[root]
            }
            return root
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let left = find(lhs), right = find(rhs)
            if left != right {
                parent[max(left, right)] = min(left, right)
            }
        }
        var seen: [String: Int] = [:]
        for (index, food) in foods.enumerated() {
            var keys = food.barcodes.map { "b:" + $0 }
            let nameKey = key(name: food.name, brand: food.brand)
            if !nameKey.isEmpty {
                keys.append("n:" + nameKey)
            }
            for key in keys {
                if let other = seen[key] {
                    union(index, other)
                } else {
                    seen[key] = index
                }
            }
        }
        var members: [Int: [String]] = [:]
        var order: [Int] = []
        for (index, food) in foods.enumerated() {
            let root = find(index)
            if members[root] == nil {
                order.append(root)
            }
            members[root, default: []].append(food.id)
        }
        return order.compactMap { members[$0] }.filter { $0.count > 1 }
    }
}

/// Ranks things used repeatedly (saved meals) by how often and how recently they were used (backlog #32).
public enum Frecency {
    /// `useCount` halves in weight for every 30 days since the last use; never-used items score 0.
    public static func score(useCount: Int, lastUsedAt: Date?, now: Date) -> Double {
        guard let lastUsedAt, useCount > 0 else { return 0 }
        let days = max(now.timeIntervalSince(lastUsedAt), 0) / 86400
        return Double(useCount) * pow(0.5, days / 30)
    }
}
