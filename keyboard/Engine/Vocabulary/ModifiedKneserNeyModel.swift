import Foundation

nonisolated struct ModifiedKneserNeyModel {
    struct Discounts {
        let values: [Double]
        init(counts: [Int]) {
            var histogram = [Int](repeating: 0, count: 5)
            for count in counts where count > 0 && count <= 4 { histogram[count] += 1 }
            self.init(histogram: histogram)
        }
        init(histogram: [Int]) {
            let n = histogram.map(Double.init)
            let y = n[1] > 0 ? n[1] / (n[1] + 2 * n[2]) : 0.75
            values = (1...3).map { k in
                // Pruned packs may lack entire frequency buckets. Use a bounded
                // absolute discount when the Chen–Goodman estimate is undefined.
                guard n[k] > 0, n[k + 1] > 0 else { return 0.75 }
                return min(Double(k), max(0, Double(k) - Double(k + 1) * y * n[k + 1] / n[k]))
            }
        }
        func discount(_ count: Int) -> Double { count > 0 ? values[min(count, 3) - 1] : 0 }
    }
    struct Context {
        let total: Int
        let discountMass: Double
        let counts: [Int32: Double]
        init(entries: [(word: Int32, count: Int)], discounts: Discounts) {
            total = entries.reduce(0) { $0 + $1.count }
            var mass = 0.0
            var prepared: [Int32: Double] = [:]
            // ID order keeps summation identical across the reference and harness.
            for entry in entries.sorted(by: { $0.word < $1.word }) where entry.count > 0 {
                let discount = discounts.discount(entry.count)
                mass += discount
                prepared[entry.word] = max(Double(entry.count) - discount, 0)
            }
            discountMass = mass
            counts = prepared
        }
    }
    let unigrams: [Int32: Int]
    let unigramTotal: Double
    let bigrams: [Int32: Context]
    let trigramDiscounts: Discounts

    init(data: LangData) {
        var uni: [Int32: Int] = [:]
        var rawBi: [Int32: [Int32: Int]] = [:]
        var continuationBi: [Int32: [Int32: Int]] = [:]
        var triHistogram = [Int](repeating: 0, count: 5)
        var hasTrigrams = false
        data.forEachTrigram { _, second, entries in
            for entry in entries where entry.count > 0 {
                hasTrigrams = true
                continuationBi[second, default: [:]][entry.word, default: 0] += 1
                if entry.count <= 4 { triHistogram[entry.count] += 1 }
            }
        }
        for id in 0..<data.wordCount {
            guard let hit = data.bigrams(after: Int32(id)) else { continue }
            for entry in hit.entries where entry.count > 0 {
                uni[entry.word, default: 0] += 1
                if !hasTrigrams { rawBi[Int32(id), default: [:]][entry.word] = entry.count }
            }
        }
        // Build discounts from histograms without retaining the full trigram corpus.
        trigramDiscounts = Discounts(histogram: triHistogram)
        let lower = hasTrigrams ? continuationBi : rawBi
        var biHistogram = [Int](repeating: 0, count: 5)
        for row in lower.values {
            for count in row.values where count > 0 && count <= 4 { biHistogram[count] += 1 }
        }
        let discounts = Discounts(histogram: biHistogram)
        bigrams = lower.mapValues { Context(entries: $0.map { (word: $0.key, count: $0.value) }, discounts: discounts) }
        unigrams = uni
        // Reserve a single unknown bucket for absent continuations and true OOVs.
        unigramTotal = Double(uni.values.reduce(0, +)) + 0.5
    }
}
