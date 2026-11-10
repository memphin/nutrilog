# Privacy

Nutrilog is built for one person's private use. The design rule is simple: **data stays on the device unless you explicitly export it.**

## What is stored
- Your food diary, custom foods, saved meals, targets and profile — in an SQLite database inside the app's sandbox, protected by iOS Data Protection (encrypted at rest).
- A local cache of Open Food Facts product records you scanned (so repeat scans work offline).
- A daily snapshot of Apple Health values you granted access to (steps, sleep, weight, body fat %, energy, resting heart rate, HRV, water). Apple Health remains the system of record; the snapshot can be deleted and recomputed at any time.
- Your optional USDA API key — in the iOS Keychain.
- A meal photo you take or choose for "Snap or describe a meal" is not stored: it is used for that one estimate and dropped.
- Automatic backups: about once a week a full export is written to a folder inside the app's sandbox (the newest seven are kept). They never leave the device unless you share one.
- Today's totals for the widgets (calories, macros, steps, sleep, weight, water) — in the app's App Group container on the device, readable only by Nutrilog and its own widget extension.

## What leaves the device
| Destination | When | What is sent |
|---|---|---|
| `world.openfoodfacts.org` | You scan a barcode not already cached, or search packaged foods online | The barcode / search text and a `User-Agent` header identifying the app |
| `images.openfoodfacts.org` | A scanned product's card shows its photo | The image address (which names the product's barcode) |
| `api.nal.usda.gov` | Only if you added a USDA key and search online | The search text and your key |
| Apple Health (on-device) | You log food or water, or enter weight | Nutrient / water / weight samples, written only with your permission |

"Snap or describe a meal" works on the device: the photo or text is read by the on-device Apple Intelligence model, or, where that isn't available, matched to foods already on the device. Neither is sent anywhere.

Siri and Shortcuts actions, the widgets, the weekly check-in reminder (a local notification, off by default) and the weekly report image all work on the device; the report image goes only where you share it.

Nothing else. There is no account, no server, no analytics, no crash-reporting SDK, no advertising SDK, and no third-party library that performs network requests.

## Optional features that change this
- **Phase 4 sync/web client** (not yet built): if you enable it, your data is sent to a server **you** host or choose. It is off by default and documented separately when it ships.
- **Open Food Facts contribution** (not yet built): if enabled, product data and photos you choose to submit are sent to Open Food Facts under their terms.

## Your data
- Export everything as JSON or CSV at any time (Settings → Export).
- Deleting the app deletes all app data. Samples written to Apple Health remain in Health until you delete them there.

## Contact
Open an issue on GitHub.
