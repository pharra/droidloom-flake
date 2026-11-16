# Troubleshooting

Both entries below are problems this flake used to work around. Upstream fixed
them in releases this flake pins, so neither workaround is applied any more.
The sections keep the symptoms and the causes so you can recognise an install
that still runs an older release.

Check the pinned release with:

```bash
nix flake metadata
grep upstreamVersion nix/package.nix
```

## `Activity start failed: -91` when launching by package name

**Symptom**

```text
$ droidloomctl launch com.futuremark.dmandroid.application
Android is ready. Launching the application (up to 120 seconds)...
droidloomctl: Android framework rejected request: IllegalStateException: Activity start failed: -91
```

`-91` is Android's `ActivityManager.START_INTENT_NOT_RESOLVED`
(`FIRST_START_FATAL_ERROR_CODE = -100`, `START_INTENT_NOT_RESOLVED = -100 + 9`).
The intent never resolved to an activity, so nothing was started. This was an
upstream launch-path limitation, not a NixOS packaging or path-replacement
problem.

**Cause, before release 40**

Without `--component`, `droidloomctl` sent only the package name.
`DroidloomTaskBackend.launch()` then built an implicit intent:

```java
new Intent(Intent.ACTION_MAIN)
        .addCategory(Intent.CATEGORY_LAUNCHER)
        .setPackage(packageName)
```

`ActivityStarter` resolves it with `MATCH_DEFAULT_ONLY`, which only accepts
filters that declare `CATEGORY_DEFAULT` themselves. Normal launcher activities
declare only `MAIN` and `LAUNCHER`, so resolution returned `null` and Android
answered `-91`. Any package failed this way, not just the one you tried.

**Fixed in release 40 (`de36544`)**

A package-only launch now queries the package's launcher activities and starts
the first one by component, as `PackageManager.getLaunchIntentForPackage` picks
it. `--component` keeps working, and a package with no launcher activity
reports `PACKAGE has no launcher activity` instead of `-91`. No workaround is
needed: `droidloomctl launch <package>` is enough.

On an older release, list the exported launchers and pass the component:

```bash
droidloomctl applications   # LABEL<TAB>PACKAGE/ACTIVITY
droidloomctl launch com.futuremark.dmandroid.application \
  --component com.futuremark.dmandroid.application/com.futuremark.flamenco.ui.splash.SplashPageActivity
```

**Confirming the diagnosis**

```bash
# Package-only launcher intents report -91 in the activity log:
droidloomctl logs -n 2000
# I/ActivityTaskManager: START u0 {act=android.intent.action.MAIN
#   cat=[android.intent.category.LAUNCHER] pkg=...} from uid 1000 result code=-91

# MATCH_DEFAULT_ONLY (0x10000) resolution finds nothing...
adb shell cmd package resolve-activity --query-flags 65536 \
  -a android.intent.action.MAIN -c android.intent.category.LAUNCHER <package>

# ...while default resolution returns the launcher component:
adb shell cmd package resolve-activity --brief \
  -a android.intent.action.MAIN -c android.intent.category.LAUNCHER <package>
```

## Advanced Protection config override

**Symptom**

`system_server` aborts during cell start and `droidloomctl logs` shows the
Advanced Protection config failing against missing Aconfig flags, or
`aconfigd` reporting that it cannot create the flag storage.

**Cause, before release 39**

The module created the cell's `data` and `metadata` directories with mode 0700
([upstream issue #13](https://github.com/denialwm/droidloom/issues/13)).
`aconfigd` runs as Android's system user, so it could not enter `/metadata`,
the flag storage never existed, and the `featureFlag`-guarded protections in
the system image's `advanced-protection-config.xml` could not be evaluated. The
flake hid that by overriding the config with a store-backed copy whose
`featureFlag` attributes were stripped.

**Fixed in release 39 (`37668ed`)**

Every cell start opens a private `metadata` root to 0755, so the stock
`advanced-protection-config.xml` from the system image works. The flake no
longer adds an `android_file_overrides` entry for that file; Android's own
config is used unchanged.

**Confirming an outdated install**

The generated cell spec still carries the old override when it contains an
`android_file_overrides` entry whose `target` is
`/system/etc/advanced-protection-config/advanced-protection-config.xml`:

```bash
grep -c 'advanced-protection-config' /etc/droidloom/cell.json
# 0 on a current flake; 1 with the removed workaround
