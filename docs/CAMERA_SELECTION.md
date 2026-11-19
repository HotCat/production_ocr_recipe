# Camera selection with mixed vendors

All five OCR applications use the same Husk camera wrappers under
`dependencies/husk-scheme/hs-src/Device/Camera/`.

MVS enumerates compatible third-party GigE Vision cameras as well as Hikvision
USB3/GigE cameras. The old default `Hikvision` selection accepted the first
supported entry without checking its manufacturer. A MindVision GigE device
could therefore be opened in place of the Hikvision USB3 device, causing camera
initialization to fail when Hikvision-specific features were configured.

The Hikvision wrapper now inspects each entry's transport-specific identity:

- USB3: manufacturer name, with vendor name also accepted as Hikvision identity.
- GigE: manufacturer name.
- Hikvision and Hikrobot brand names are recognized without case sensitivity.
- Third-party and unknown manufacturers are ignored by this backend. The
  independent MindVision backend and its existing names are unchanged.
- Fixed-size SDK strings are read with their declared bounds, including serial
  fields that are not NUL terminated. Unsupported transport unions are not read.

`Hikvision` chooses a **unique** Hikvision/Hikrobot USB3 or GigE camera, regardless
of enumeration order. With one Hikvision USB3 and one MindVision GigE camera,
leave the existing launcher value `Hikvision` unchanged and keep both connected.
If no matching camera exists, or more than one matches, initialization fails
with device identity diagnostics rather than opening the first arbitrary device.
A busy/misconfigured selected device is not replaced with another camera.

To select among several Hikvision cameras, use `Hikvision:SERIAL`, for example:

```sh
SEQUENCE_OCR_CAMERA=Hikvision:YOUR_ACTUAL_SERIAL scripts/run-app.sh 'Barcode+Sequence'
```

Use the application's camera environment variable listed in the main README.
For the launcher, add that string to the JSON `cameras` list, click 重新读取配置,
select it in the camera dropdown, then save parameters. Obtain the exact serial
from MVS or the launcher's 运行日志. The log lists every discovered device with
transport, manufacturer, vendor, model and serial, and identifies the chosen
device. The generic `Hikvision` value does not require a serial number.

## Development verification

```sh
scripts/test-camera-selection.sh
scripts/build-all.sh
```

The C++ regression compiles the **actual Camera.cpp constructor** with fake MVS
entry points and installed SDK headers. It does not link the vendor SDK runtime,
open USB/Ethernet cameras, acquire frames, or touch a PLC. It covers both device
orders, null entries, other USB vendors, USB vendor identity, Hikvision GigE,
explicit serials, missing cameras, ambiguous matches, duplicate serials,
unterminated SDK strings, unsupported transports and enumeration errors. It
asserts the exact device passed to `MV_CC_CreateHandle`, including that no handle
is created on failed selection.

The shared Haskell wrapper declares the selection header as a compile dependency,
so changing the policy rebuilds it and the five application binaries. Source
wrapper files are explicitly excluded from the executable-name ignore rule;
external vendor SDK headers/libraries remain outside this repository.

After rebuilding, exit and reopen each production application to load its new
binary. Hardware acceptance should keep both cameras connected, use `Hikvision`,
and confirm the log selects the Hikvision USB3 serial and the live view updates.
The regression verifies the selection logic; it does not replace that physical
acceptance check. Close the official MVS live-view window before opening the
production application so it does not hold exclusive access to the camera.
