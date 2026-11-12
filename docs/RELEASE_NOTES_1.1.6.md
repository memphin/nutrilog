# Vitalion 1.1.6 — release notes

Changes since 1.1.5. The first section is written for the App Store "What's New" and TestFlight "What to Test"
fields; the rest is for testers.

## What's New

**Training days**
- Pick your training weekdays and a boost in Settings → Training days. On a training day your calorie target and
  water goal go up by the boost; the extra calories go to carbs, while protein, fat and fiber stay the same.
- Switch any single day on or off from the diary, the meal plan or the calendar (long-press a day). Today shows a
  "Training day" pill, and the calendar marks training days with a dumbbell.

**Croatian**
- Vitalion is now available in Croatian, including widgets, Siri and Shortcuts, and the names of all 631 built-in
  foods. The app follows your iPhone's language; to choose one for Vitalion only, use Settings → Vitalion → Language.
- Food search finds a food by its English or Croatian name and ignores accents.

**Fixed**
- Sleep streak: a short night now ends the streak the same morning instead of still showing yesterday's count.
- Counts of one read correctly ("1 food", "1 hour"), and large numbers are grouped ("2,500 ml").

## What to test

- Settings → Training days: select today's weekday. Today shows the pill, and the calorie and water goals are higher
  by the boost. Switch today off from the chip in the diary: the goals go back.
- Change the weekdays or the boost: past days in the calendar keep the status they had.
- Set the app language to Croatian and go through Today, Add food, Trends and Settings. Wording corrections from a
  native speaker are welcome.
- Sleep: with last night's sleep under your goal, the sleep tile shows no streak badge.

## Notes

- New database migration `015_training_days` (the training schedule and the per-day overrides). Backups and exports from 1.1.6
  can't be imported into older versions.
- The weekly check-in and the expenditure estimate keep using the base target, so a training boost never becomes
  part of it.
