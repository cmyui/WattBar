# WattBar

Tiny macOS menu bar battery-flow and network-activity indicator.

It reads `AppleSmartBattery` telemetry through IOKit every 5 seconds and shows
net battery watts in the menu bar. Positive watts enter the battery; negative
watts leave it. Power-source notifications trigger immediate and follow-up
samples around plug and unplug transitions, while telemetry age makes repeated
underlying samples explicit.

Network figures come from macOS byte counters, read every second while the
menu is open and every two seconds otherwise, and do not generate any network
traffic. WattBar shows current receive/send rates, a rolling graph, connection
and persistent daily totals, and whether macOS marks the current path as an
expensive Personal Hotspot or constrained by Low Data Mode.

Sampling pauses while the displays sleep and resumes with a fresh sample when
they wake. Traffic during the pause counts toward the totals but not toward
the rates or graphs.

The Preferences menu controls launch at login, graph visibility and duration,
network totals, bytes-versus-bits display, and battery-flow coloring.

Build:

```sh
./build.sh
```

Run:

```sh
open build/WattBar.app
```

The larger graph in the menu shows five minutes of network history and rolling
peaks. The compact menu-bar graph can show 30, 45, or 60 seconds.
