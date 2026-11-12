#if DEBUG
    import Core
    import Foundation

    /// Made-up days with clear links for `-uiScreen correlations`, `correlationDetail`, `correlationWeightDetail` and
    /// `correlationExplorer` (screenshots, UI checks): hydration lifts the next day's HRV and that night's sleep a little,
    /// calories and steps move the weight trend week by week. Some days miss values or are only partly logged.
    /// Deterministic. Debug builds only.
    enum CorrelationSampleData {
        static func days(endingOn today: LocalDay, count: Int = 400) -> [DayStats] {
            var random = SplitMix(seed: 53)
            let first = today.adding(days: -count)
            var trend = 86.0
            var waterBefore = 2000.0
            var result: [DayStats] = []
            for index in 0 ... count {
                let week = Double(index / 7)
                var day = DayStats(day: first.adding(days: index))
                let water = max(700, 2000 + 450 * sin(Double(index) * 0.9) + random.noise(450))
                let steps = max(1500, 8500 + 2500 * sin(week * 1.3) + random.noise(2500))
                let kcal = 2350 + 250 * sin(week * 0.7 + 1) + random.noise(300)
                day.waterMl = index % 17 == 5 ? nil : water
                day.hrvMs = index % 13 == 3 ? nil : 46 + 6 * (waterBefore - 2000) / 500 + random.noise(9)
                day.sleepMin = Int(425 + 10 * (waterBefore - 2000) / 500 + random.noise(45))
                day.steps = Int(steps)
                day.activeKcal = 150 + steps * 0.04 + random.noise(60)
                day.basalKcal = 1760
                day.restingHR = 56 - (steps - 8500) / 2000 + random.noise(3)
                // Every eleventh day unlogged, every nineteenth only breakfast.
                let partial = index % 19 == 2
                if index % 11 != 7 {
                    let logged = partial ? kcal * 0.3 : kcal
                    day.intake = Nutrients(kcal: logged, proteinG: logged * 0.25 / 4, carbsG: logged * 0.45 / 4, fatG: logged * 0.3 / 9)
                    day.entryCount = partial ? 1 : 3 + index % 3
                }
                let burned = 1760 + 150 + steps * 0.04 + 0.1 * kcal
                trend += (kcal - burned) / Energy.kcalPerKg
                day.trendKg = trend
                day.weightKg = trend + random.noise(0.5)
                waterBefore = water
                result.append(day)
            }
            return result
        }

        static func analysis(_ card: CorrelationCard, today: LocalDay, unit: EnergyUnit) -> CorrelationAnalysis {
            CorrelationAnalysis.make(
                card.spec, period: .threeMonths, stats: days(endingOn: today), today: today, unit: unit,
                firstWeekday: Calendar.current.firstWeekday,
            )
        }
    }

    /// SplitMix64: repeatable noise without `SystemRandomNumberGenerator`.
    private struct SplitMix {
        var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in −amplitude … amplitude.
        mutating func noise(_ amplitude: Double) -> Double {
            (Double(next() >> 11) / Double(1 << 53) * 2 - 1) * amplitude
        }
    }
#endif
