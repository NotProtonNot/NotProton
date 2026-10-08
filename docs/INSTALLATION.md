# Install NotProton

1. Download **NotProton.zip** from this fork’s latest linked preview release.
2. Unzip it and copy **NotProton.app** to **Applications**. Open that copy.
3. In the setup guide, confirm native Steam and an activated, supported CrossOver build.
4. The permission page checks write access to Steam. If it shows a green check, click **Continue**. Otherwise click **Open System Settings** and go to **Privacy & Security → App Management**.
5. If NotProton is missing, click **+**, select `/Applications/NotProton.app`, click **Open** and turn on its switch. Return to NotProton. If macOS requires restarting the app, restart it and reopen the guide from **Settings**. The check is repeated when the app becomes active; **Check again** is also available.
6. Quit games, install the integration and finish runtime setup. A ready status comes from checked files.
7. Click **Open Steam**. The setup closes once Steam opens successfully.
8. In Steam’s **Library**, right-click a Windows game and choose **Properties → Compatibility**.
9. Enable **Force the use of a specific Steam Play compatibility tool**. Then choose **CrossOver 26.3**, or the installed CrossOver profile you need, from the dropdown.
10. Close Properties and click **Play**. Check picture, controls and saves.

The Steam checkbox in step 9 is required before its runtime dropdown appears. This is **Compatibility**, not macOS Accessibility. NotProton does not need Accessibility access to choose a runtime. Steam may separately request Input Monitoring for a controller; grant that to Steam only when needed. Full Disk Access is not a general setup requirement.

This fork’s preview is ad hoc signed, not Apple-notarized. If macOS blocks it and you trust this download, use the individual **Open Anyway** option under Privacy & Security. Keep Gatekeeper enabled. These changes remain a contribution, not an official upstream release.
