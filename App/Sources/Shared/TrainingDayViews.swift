import DesignSystem
import Foundation
import SwiftUI

// Training days: a day's calorie target and hydration goal go up by the schedule's boost (Settings → Training days).
// The dumbbell marks them: filled on a training day, outlined on a rest day.

/// Texts of the training-day marks.
enum TrainingDayFormat {
    /// The SF Symbol of a training day (filled) or a rest day (outlined).
    static func symbol(isTraining: Bool) -> String {
        isTraining ? "dumbbell.fill" : "dumbbell"
    }

    /// "+10%" (or "+10 %"): the boost, signed, in `locale`'s percent format.
    static func boost(_ percent: Int, locale: Locale = .autoupdatingCurrent) -> String {
        percent.formatted(.percent.sign(strategy: .always()).locale(locale))
    }

    /// "Training day · +10%", Today's pill.
    static func pill(_ percent: Int, locale: Locale = .autoupdatingCurrent) -> String {
        String(localized: "Training day · \(boost(percent, locale: locale))", locale: locale)
    }

    /// "Training day, goals raised by 10%", the pill for VoiceOver.
    static func spokenPill(_ percent: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let amount = percent.formatted(.percent.locale(locale))
        return String(localized: "Training day, goals raised by \(amount)", locale: locale)
    }
}

/// Today's "Training day · +10%" on a training day. Shows, never changes: the switch is in the diary.
struct TrainingDayPill: View {
    let boostPercent: Int

    var body: some View {
        Label(TrainingDayFormat.pill(boostPercent), systemImage: TrainingDayFormat.symbol(isTraining: true))
            .font(NL.Typography.label.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, NL.Spacing.m)
            .padding(.vertical, NL.Spacing.xs)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TrainingDayFormat.spokenPill(boostPercent))
    }
}

/// The diary's training-day switch under the day's summary: tinted with the boost ("+10%") on a training day,
/// outlined otherwise.
struct TrainingDayToggle: View {
    let isOn: Bool
    /// The boost of the day's schedule, shown while on.
    let boostPercent: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NL.Spacing.xs) {
                Image(systemName: TrainingDayFormat.symbol(isTraining: isOn))
                Text("Training day")
                if isOn {
                    Text(TrainingDayFormat.boost(boostPercent)).monospacedDigit()
                }
            }
            .font(NL.Typography.label.weight(isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, NL.Spacing.m)
            .padding(.vertical, NL.Spacing.xs)
            .background {
                if isOn {
                    Capsule().fill(Color.accentColor.opacity(0.15))
                } else {
                    Capsule().strokeBorder(Color.secondary.opacity(0.4))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Training day")
        .accessibilityValue(isOn ? TrainingDayFormat.boost(boostPercent) : "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint("Raises this day's calorie and hydration goals")
    }
}

/// The meal plan's training-day switch in a day's header: a filled dumbbell on a training day.
struct TrainingDayButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: TrainingDayFormat.symbol(isTraining: isOn))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .padding(.horizontal, NL.Spacing.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Training day")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint("Raises this day's calorie and hydration goals")
    }
}
