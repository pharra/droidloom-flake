# Troubleshooting

## `Activity start failed: -91` when launching by package name

**Symptom**

```text
$ droidloomctl launch com.futuremark.dmandroid.application
Android is ready. Launching the application (up to 120 seconds)...
droidloomctl: Android framework rejected request: IllegalStateException: Activity start failed: -91
```

`-91` is Android's `ActivityManager.START_INTENT_NOT_RESOLVED`
(`FIRST_START_FATAL_ERROR_CODE = -100`, `START_INTENT_NOT_RESOLVED = -100 + 9`).
The intent never resolved to an activity, so nothing was started. This is an
upstream launch-path limitation, not a NixOS packaging or path-replacement
problem.

**Cause**

Without `--component`, `droidloomctl` sends only the package name.
`DroidloomTaskBackend.launch()` then builds an implicit intent:

```java
new Intent(Intent.ACTION_MAIN)
        .addCategory(Intent.CATEGORY_LAUNCHER)
        .setPackage(packageName)
```

`ActivityStarter` resolves it with `MATCH_DEFAULT_ONLY`, which only accepts
filters that declare `CATEGORY_DEFAULT` themselves. Normal launcher activities
declare only `MAIN` and `LAUNCHER`, so resolution returns `null` and Android
answers `-91`. Any package fails this way, not just the one you tried.

**Workaround: launch with an explicit component**

List the exported launchers first:

```bash
droidloomctl applications
```

Each line is `LABEL	PACKAGE/ACTIVITY`. Pass that component to `launch`:

```bash
droidloomctl launch com.futuremark.dmandroid.application \
  --component com.futuremark.dmandroid.application/com.futuremark.flamenco.ui.splash.SplashPageActivity
```

The Droidloom home launcher already launches with explicit components, so this
only affects direct `droidloomctl launch <package>` calls.

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
