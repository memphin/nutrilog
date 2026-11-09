# Releasing to TestFlight

Pushing a `vMAJOR.MINOR.PATCH` tag runs the `testflight` job in `.github/workflows/ci.yml` (SPEC §11, backlog #30).
After the package and app tests pass on the tagged commit, the job:

1. Archives the app with `xcodebuild archive` (Release, `generic/platform=iOS`).
2. Signs and uploads it with `xcodebuild -exportArchive`, using `Config/ExportOptions.plist`
   (`method: app-store-connect`, `destination: upload`).

Signing is automatic and cloud-managed. An App Store Connect API key is passed with `-authenticationKeyPath`,
`-authenticationKeyID` and `-authenticationKeyIssuerID`, together with `-allowProvisioningUpdates`. That way, no
certificates or provisioning profiles are stored in the repository or in GitHub. The team ID also stays out of the
repo: the job adds it to a copy of the export options at build time.

| Value | Comes from |
|---|---|
| Marketing version (`CFBundleShortVersionString`) | The tag: `v0.2.0` → `0.2.0` |
| Build number (`CFBundleVersion`) | `git rev-list --count HEAD`, the number of commits in the tagged history |

`MARKETING_VERSION` in `project.yml` is only used for local builds. Keep it at the version you are about to tag. If it
doesn't match the tag, the job shows a warning, and the tag wins.

## One-time setup (repository owner)

You only do these steps once. They need an active Apple Developer Program membership, and the API key step needs the
Account Holder or Admin role.

### 1. Register the App ID

1. Open [developer.apple.com/account](https://developer.apple.com/account) and go to **Certificates, Identifiers &
   Profiles → Identifiers**. Click **+**, choose **App IDs**, then **App**.
2. Fill in:
   - **Description:** `Nutrilog`
   - **Bundle ID:** Explicit, `hr.ivanjuric.nutrilog`
3. Under **Capabilities**, enable **HealthKit**, which also covers background delivery.
4. Click **Continue**, then **Register**.

If the ID already exists from running the app on your phone, make sure HealthKit is enabled on it.

The team also needs **at least one registered device**. Without one, automatic signing can't make the development
profile that the archive step uses, and fails with "Your team has no devices". To register your iPhone, run the app on
it once from Xcode with your team selected, or add it under **Devices**.

### 2. Create the App Store Connect app record

1. Open [appstoreconnect.apple.com](https://appstoreconnect.apple.com) and go to **Apps**. Click **+**, then **New App**.
2. Fill in:
   - **Platforms:** iOS
   - **Name:** `Nutrilog`. The name must be unique on the App Store. If it is taken, pick another, such as
     `Nutrilog Tracker`. It does not have to match the name on the home screen.
   - **Primary Language:** your choice
   - **Bundle ID:** `hr.ivanjuric.nutrilog`
   - **SKU:** `nutrilog`
   - **User Access:** Full Access
3. Click **Create**. You don't need to fill in a store listing for TestFlight.
4. Go to **TestFlight → Internal Testing**. Click **+** and create a group, for example `Me`. Add yourself as a tester,
   and turn on **Automatically distribute builds** so each upload reaches your phone without extra clicks.

You won't be asked about export compliance: `ITSAppUsesNonExemptEncryption` is already set to `false` in
`project.yml`.

### 3. Create the App Store Connect API key

1. In App Store Connect, go to **Users and Access → Integrations → App Store Connect API → Team Keys**. If this is
   the first key, the Account Holder must click **Request Access** first.
2. Click **Generate API Key** (or **+**) and fill in:
   - **Name:** `GitHub Actions TestFlight`
   - **Access:** **Admin**. Automatic cloud signing needs this role to create the distribution certificate and the
     App Store profile. **App Manager** can upload, but it can't sign.
3. Click **Download** and save `AuthKey_<KEY_ID>.p8`. **You can download it only once.** Keep it out of the repo:
   `*.p8` is git-ignored, but store it outside the checkout anyway.
4. Write down two values from the same page:
   - the **Key ID**, the 10-character ID in the key's row;
   - the **Issuer ID**, the UUID above the list of keys.

### 4. Add the GitHub repository secrets

Find your Team ID at [developer.apple.com/account](https://developer.apple.com/account) under **Membership details**.
It is 10 characters long.

Add the secrets in GitHub under **Settings → Secrets and variables → Actions → New repository secret**, or with
`gh` from the repo:

```sh
gh secret set ASC_KEY_ID --body "<KEY_ID>"
gh secret set ASC_ISSUER_ID --body "<ISSUER_ID>"
base64 -i /path/to/AuthKey_<KEY_ID>.p8 | gh secret set ASC_KEY_P8
gh secret set APPLE_TEAM_ID --body "<TEAM_ID>"
# Optional:
gh secret set USDA_FDC_API_KEY --body "<your FDC key>"
gh secret set OFF_USER_AGENT_CONTACT --body "https:/\$()/github.com/memphin/nutrilog"
```

| Secret | Required | What it is |
|---|---|---|
| `ASC_KEY_ID` | yes | API key ID, for example `2X9R4HXF34` |
| `ASC_ISSUER_ID` | yes | Issuer ID, a UUID |
| `ASC_KEY_P8` | yes | The `.p8` file encoded as **base64**, as one line |
| `APPLE_TEAM_ID` | yes | Apple Developer Team ID |
| `USDA_FDC_API_KEY` | no | Built-in USDA FoodData Central key (ADR-0004, mode 2). If it is missing, the job only warns: users can still paste a key in Settings. |
| `OFF_USER_AGENT_CONTACT` | no | Overrides the contact sent in the User-Agent header to Open Food Facts. The default comes from `Config/Secrets.xcconfig.template`. In an xcconfig, `//` starts a comment, so write URLs as `https:/$()/…`. |

If any required secret is missing, the job fails on its first step and names the secrets it needs.

## Cutting a release

1. On `main`, set `MARKETING_VERSION` in `project.yml` to the new version, run `xcodegen generate`, and merge that
   through a PR.
2. Tag the merged commit and push the tag:

   ```sh
   git switch main && git pull
   git tag -a v0.2.0 -m "Nutrilog 0.2.0"
   git push origin v0.2.0
   ```

3. Watch the **CI** run for the tag. When **TestFlight upload** is green, App Store Connect processes the build. This
   usually takes 5 to 30 minutes. The build then shows up in TestFlight for the internal group.

TestFlight builds expire after 90 days. To keep the app on your phone, push a new patch tag before then.

## Troubleshooting

- **"Cloud signing permission error" or "No profiles for 'hr.ivanjuric.nutrilog'":** the API key needs the **Admin**
  role (step 3), and the App ID must exist with HealthKit enabled (step 1).
- **"Your team has no devices from which to generate a provisioning profile":** register a device first. Running
  the app once on your iPhone from Xcode does this (see step 1).
- **"The bundle version must be higher than the previously uploaded version":** the build number comes from the commit
  count. Re-running the job for a tag that already uploaded reuses the same number. Make a new commit and tag a new
  version instead.
- **Accumulating "Created via API" development certificates:** automatic signing may create a development certificate
  on each fresh CI machine. Revoke old ones now and then under **Certificates**. Revoking them does not affect builds
  that are already installed.
- **Rotating the key:** revoke it in App Store Connect, generate a new one (step 3), and update `ASC_KEY_ID` and
  `ASC_KEY_P8`.
