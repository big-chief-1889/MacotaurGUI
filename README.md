# MacotaurGUI

Mac app for [Macotaur](https://github.com/big-chief-1889/Macotaur), a Tari C29 GPU miner for Apple Silicon.

## Requirements

- An Apple Silicon Mac running macOS 15 or later
- Xcode to build (the Command Line Tools alone lack SwiftUI's macros)

## Build

Clone both repos into the same folder; the app builds against `../Macotaur`.

```
git clone https://github.com/big-chief-1889/Macotaur
git clone https://github.com/big-chief-1889/MacotaurGUI
cd MacotaurGUI
./scripts/build-app.sh
open build/Macotaur.app
```

## Using it

Paste your Tari wallet on the dashboard (or in Settings), pick a pool in Settings and start mining. The window is a short list of readings: speed, today's shares, the GPU's power and clock where the Mac reports them, heat and, with Kryptex, the pool balance and the time to the next payout. Hover over a reading for more. Show Log opens the activity log. Closing the window quits the app, which stops mining first. The app keeps the Mac awake while it mines, and writes an activity log to `~/Library/Logs/Macotaur/activity.log`.

The Power slider sets how much of the time the GPU works, from 10% to 100%. Lower runs cooler and uses less power. Changes apply at once, even while mining.

Macotaur never starts mining by itself, and there is no start-at-login option. Mining runs until you press Stop, which gives the GPU memory back at once. On 8 GB Macs the solver runs in a low-memory mode that needs about 40% less GPU memory.

The last 24 hours of speed are kept in `~/Library/Application Support/Macotaur/history-v1.json` for the payout estimate, with today's share counts in `stats-v1.json` next to it.

## Development

`--demo [air|pro|mini|studio|m1]` fills the app with sample data for one of five kinds of Mac and touches nothing real: no mining, network, telemetry or settings writes. `--snapshot DIR/NAME.png SECS` waits SECS, renders the dashboard in each of its states and the two settings tabs to `DIR/NAME-<screen>.png` and quits; `--snapshot-only TEXT` limits it to names containing TEXT. `--power-debug` prints the power and clock sources this Mac reports.

```
build/Macotaur.app/Contents/MacOS/Macotaur --demo --snapshot /tmp/shots/s.png 1
swift test
```

`MACOTAUR_GPU_TESTS=1 swift test` also runs the live tests, which mine on the GPU against a local mock pool for about two minutes.

GPU power, clock and fan readings come from IOReport and the SMC (`Sources/CMacotaurPower`). IOReport is a private API, so it's loaded at runtime and every reading is optional. The miner package uses public APIs only.

The app icon is drawn in code. To regenerate `Resources/AppIcon.icns`, run `swift scripts/make-icon.swift`.

## License

BSD 3-Clause. The app includes the miner, which has parts based on John Tromp's reference code; see [THIRD_PARTY_NOTICES](https://github.com/big-chief-1889/Macotaur/blob/main/THIRD_PARTY_NOTICES) in the Macotaur repo. `build-app.sh` copies both files into the app.
