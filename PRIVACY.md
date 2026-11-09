# Privacy

Nutrilog is built for one person's private use. The design rule is simple: **data stays on the device unless you explicitly export it.**

## What is stored
- Your food diary, custom foods, recipes, saved meals, targets and profile — in an SQLite database inside the app's sandbox, protected by iOS Data Protection (encrypted at rest).
- A local cache of Open Food Facts product records you scanned (so repeat scans work offline).
- A daily snapshot of Apple Health values you granted access to (steps, sleep, weight, body fat %, energy, resting heart rate, HRV, water). Apple Health remains the system of record; the snapshot can be deleted and recomputed at any time.
- Your optional USDA API key — in the iOS Keychain.

## What leaves the device
| Destination | When | What is sent |
|---|---|---|
| `world.openfoodfacts.org` | You scan a barcode not already cached, or search packaged foods online | The barcode / search text and a `User-Agent` header identifying the app |
| `images.openfoodfacts.org` | A scanned product's card shows its photo | The image address (which names the product's barcode) |
| `api.nal.usda.gov` | Only if you added a USDA key and search online | The search text and your key |
| Apple Health (on-device) | You log food or water, or enter weight | Nutrient / water / weight samples, written only with your permission |

Nothing else. There is no account, no server, no analytics, no crash-reporting SDK, no advertising SDK, and no third-party library that performs network requests.

## Optional features that change this
- **Phase 4 sync/web client** (not yet built): if you enable it, your data is sent to a server **you** host or choose. It is off by default and documented separately when it ships.
- **Open Food Facts contribution** (not yet built): if enabled, product data and photos you choose to submit are sent to Open Food Facts under their terms.

## Your data
- Export everything as JSON or CSV at any time (Settings → Export).
- Deleting the app deletes all app data. Samples written to Apple Health remain in Health until you delete them there.

## Contact
Open an issue on GitHub.
