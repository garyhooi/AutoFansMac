# Distributing AutoFansMac

Nothing here is required to *run* the app, and nothing here costs money except the last
option. Pick the row that matches what you have.

| Way | Signature | Cost | Recipient has to |
|---|---|---|---|
| Build from source | their own Apple ID, automatic signing | free | nothing |
| Unsigned community build | ad-hoc (no certificate) | free | clear the quarantine once |
| Developer ID + notarize | Developer ID, notarized | US$99/year | nothing |

Whichever you pick, fan control goes through the privileged helper, and the helper only
obeys a client it trusts. That trust is a **code-signature requirement**
(`HelperClientRequirement` in `Shared/HelperProtocol.swift`): Apple-anchored, plus the
signing team. A build with no certificate has no team to pin — which is exactly why the
unsigned build is a separate compile (`AUTOFANSMAC_UNSIGNED_BUILD`) and not just an
unsigned Developer ID build.

## 1. Build from source

The path that costs nothing and needs no trust decisions from anyone:

```sh
git clone <repo> AutoFansMac && cd AutoFansMac
open AutoFansMac.xcodeproj        # Xcode → Signing & Capabilities → your team, then Run
```

Xcode's automatic signing gives you an Apple Development certificate (a free Apple ID is
enough for local development), which already satisfies the helper's requirement — so fan
control works from a normal Run build. `Docs/README-DEV.md` covers the rest.

If you want the signed app outside Xcode's DerivedData:

```sh
Scripts/build.sh                  # Release, signed with whatever Xcode would use
xcodebuild -project AutoFansMac.xcodeproj -scheme AutoFansMac -configuration Release \
    DEVELOPMENT_TEAM=<YOUR_TEAM_ID> build
```

Re-badging it as your own app means changing the team in **three** places — the project's
`DEVELOPMENT_TEAM` (all three targets), `HelperConstants.teamIdentifier` and the bundle
ids in `Shared/HelperProtocol.swift`, and `Label`/`MachServices`/
`AssociatedBundleIdentifiers` in `Support/com.autofansmac.AutoFansMac.helper.plist`.
The daemon checks the connecting client against that team, so a mismatch means every
connection is refused — silently, from the app's point of view.

## 2. The unsigned community build

For shipping a download without an Apple Developer account:

```sh
Scripts/package-unsigned.sh
# → build/AutoFansMac-<version>-unsigned.dmg
```

What the script does, and why each step exists:

- builds Release with `CODE_SIGNING_ALLOWED=NO` and
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS=AUTOFANSMAC_UNSIGNED_BUILD`;
- writes `AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS=1` into the **bundled** LaunchDaemon plist,
  so the daemon the app registers stops checking signatures;
- copies `Scripts/dev-install-helper.sh` into the app at
  `Contents/Resources/install-helper.sh`, as a fallback when `SMAppService` refuses an
  ad-hoc app;
- ad-hoc signs framework → helper → app, inside out, after every edit;
- verifies the helper is self-contained and the app's libraries are in the bundle;
- writes the DMG with a note that contains the two commands the user needs.

### What the recipient does

```sh
xattr -dr com.apple.quarantine /Applications/AutoFansMac.app     # once, after dragging it in
```

Until that runs, macOS refuses the first launch and offers to move the app to the Trash
(the app is ad-hoc signed, not notarized, so Gatekeeper has nothing to verify). Dragging
to `/Applications` is not cosmetic: the LaunchDaemon plist's `ProgramArguments` is the
absolute path `/Applications/AutoFansMac.app/...`.

Fan control then needs the helper, which the app offers to install. If that fails:

```sh
sudo /Applications/AutoFansMac.app/Contents/Resources/install-helper.sh install \
    /Applications/AutoFansMac.app --allow-untrusted
```

**Upgrading over a signed build.** A daemon installed earlier by an Apple-signed build
stays in `/Library/PrivilegedHelperTools` and keeps authorising by signing team, so it
refuses the unsigned app and the app reports *"registered but not responding"*. The
daemon's log says which:

```sh
log show --last 5m --predicate 'process == "AutoFansMacHelper"' --info | grep REFUSED
# REFUSED connection from pid … — signature does not satisfy: … certificate leaf[subject.OU] = "TEAMID"
```

Run the installer above (it boots the old job out first) and press **Reconnect**.

### What you are giving up

- **No Gatekeeper verification.** The user cannot distinguish your build from a
  repackaged one. Publish the SHA-256 of the DMG next to it and say so.
- **The helper accepts any local client.** That is the trade the unsigned build makes: on
  an official build only an app signed by the team can move the fans as root. Here any
  process on the machine can. It is still gated by root privilege at launchd, and the
  dead-man switch and clamping still apply — but it is a weaker guarantee, and worth
  saying plainly in the release notes.
- **No update story.** macOS will not help the user keep it current.

## 3. Signed and notarized

With a Developer ID certificate (`security find-identity -v -p codesigning` must list one)
and stored notary credentials:

```sh
# one-time: an app-specific password, or an App Store Connect API key (--key/--key-id/--issuer)
xcrun notarytool store-credentials AutoFansMacNotary \
    --apple-id you@example.com --team-id <TEAM_ID> --password <app-specific-password>

# per release, in this order
Scripts/sign-and-notarize.sh                  # archive → Developer ID sign → notarize → staple the app
Scripts/package-dmg.sh                        # DMG around the *stapled* app
xcrun notarytool submit "build/AutoFansMac-1.0.0.dmg" --keychain-profile AutoFansMacNotary --wait
xcrun stapler staple "build/AutoFansMac-1.0.0.dmg"
xcrun stapler validate "build/AutoFansMac-1.0.0.dmg"
spctl --assess --type open --context context:primary-signature -v "build/AutoFansMac-1.0.0.dmg"
```

The DMG must be rebuilt after the app is stapled, not before. `Scripts/sign-and-notarize.sh`
defaults to `TEAM_ID=93WWDR82K2`, `SIGN_IDENTITY="Developer ID Application"` and
`KEYCHAIN_PROFILE=AutoFansMacNotary`; all three are environment overrides.

Bump `CURRENT_PROJECT_VERSION` / `MARKETING_VERSION` in the project and
`HelperConstants.helperVersion` in `Shared/HelperProtocol.swift` when the daemon changes —
the app compares that version over XPC and re-registers the daemon when it differs.

## Gatekeeper commands, in one place

| Command | What it tells you |
|---|---|
| `codesign -dv --verbose=4 App.app` | identity, team, hardened runtime flag |
| `codesign --verify --strict App.app` | the signature is internally consistent |
| `spctl --assess --type execute -v App.app` | what Gatekeeper will do — `source=Unnotarized Developer ID` means "signed, not notarized" |
| `spctl --assess --type open -v App.dmg` | same, for the disk image |
| `xattr -dr com.apple.quarantine App.app` | clears the download flag so the app opens |
| `xattr -l App.app` | shows whether the quarantine flag is actually set |

Right-click → Open also clears the flag for one app, without a Terminal. Disabling
Gatekeeper machine-wide (`sudo spctl --master-disable`) works too, and is a bad
trade — do not tell users to do that.
