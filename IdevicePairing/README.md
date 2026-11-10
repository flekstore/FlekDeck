# IdevicePairing

`IdevicePairing.dylib` is the part of [idevice](https://github.com/jkcoxson/idevice)
(MIT) that FlekDeck calls itself, rather than through StikJIT. It loads it to
create a pairing file on the device itself, on iOS 27 and later (see
`LiveContainerSwiftUI/Utilities/LCDevicePairing.m`), and to record the device's
own log while built-in JIT's check runs, for a report sent to support (see
`LiveContainerSwiftUI/Utilities/LCDeviceLog.m`).

It holds the functions listed in `exports.txt` and what they need, nothing
else, and is built for devices only (arm64, iOS 17 and later).

`build.sh` rebuilds it. It links the dylib from the static idevice library kept
in the [StikJIT](https://github.com/StikDebug/StikJIT) repository, taken at a
pinned commit and checked against a pinned hash. That library is 57 MB, so it
is downloaded for the build rather than kept here.
