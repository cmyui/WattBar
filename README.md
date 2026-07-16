# WattBar

Tiny macOS menu bar power indicator.

It reads `AppleSmartBattery` telemetry through IOKit every 5 seconds and shows
net battery watts in the menu bar. The menu includes adapter input, adapter max
wattage, estimated whole-system watts, charge percentage, and passive receive
and send rates for the primary network interface. Network figures come from
macOS byte counters and do not generate any network traffic.

Build:

```sh
./build.sh
```

Run:

```sh
open build/WattBar.app
```

Negative watts means the battery is helping power the Mac. Positive watts means
the battery is gaining charge.
