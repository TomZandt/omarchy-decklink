# DeckLink

Use a Blackmagic DeckLink capture card as a webcam, from the
[Omarchy](https://omarchy.org) bar. Start and stop the virtual camera with a
click, and pick the card, input connection, video mode and pixel format from a
panel. Chrome, Firefox, Zoom and anything else that speaks V4L2 sees it as
"DeckLink Virtual Camera".

DeckLink is an unofficial community plugin. It is not affiliated with,
endorsed by, or connected to Blackmagic Design or Omarchy.

> **Tested hardware: DeckLink Mini Recorder only.**
> Every claim below was verified on one DeckLink Mini Recorder (the name the
> driver reports; Blackmagic sells it today as the Mini Recorder HD) on Arch
> Linux. Other models use the
> same GStreamer element and *should* work, but are **untested**. They may need
> a different connection, mode or pixel format. See [Other DeckLink
> models](#other-decklink-models).

## It never starts by itself

A DeckLink card serves one app at a time. While this plugin's camera is
running, OBS or DaVinci Resolve can't open the card, and the other way round.
So the camera only runs when you start it, and stopping it hands the card
straight back. If OBS or Resolve is running, the tooltip warns that it may be
holding the card. A failed start does not retry.

## Usage

| Click  | Action                                  |
|--------|-----------------------------------------|
| Left   | Open the settings panel                 |
| Right  | Start / stop the camera                 |
| Middle | Refresh the status                      |

The icon is dimmed when off, normal when live, and in the alert colour when the
camera is running but there is **no signal** (it is streaming black). In the
panel, `S` toggles the camera, `R` refreshes and `Esc` closes.

Changing a setting restarts the camera if it is running, and just saves it
otherwise. A fixed video mode with Pixel format "Auto" uses 8-bit YUV.

## Requirements

On Arch (package names as of writing):

| What | Package |
|------|---------|
| Omarchy with the Quickshell shell | `omarchy` |
| Blackmagic Desktop Video drivers (the `blackmagic_io` kernel module) | `decklink` (AUR) |
| GStreamer DeckLink plugin | `gst-plugins-bad-libs` |
| Virtual camera kernel module | `v4l2loopback-dkms` |
| Desktop notifications | `libnotify` |
| Live preview in the panel | `qt6-multimedia` |

### Virtual camera setup (needs root, once)

The plugin finds its virtual camera by the label "DeckLink Virtual Camera" and
refuses to start without one. It never falls back to `/dev/video0`, which could
be a real webcam. Create the device by copying
[system/v4l2loopback.conf](system/v4l2loopback.conf) to
`/etc/modprobe.d/v4l2loopback.conf` and making the module load at boot:

```bash
sudo cp system/v4l2loopback.conf /etc/modprobe.d/v4l2loopback.conf
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf
sudo modprobe v4l2loopback
```

If you already have v4l2loopback configured with that label, any `video_nr`
works. If the module is already loaded with other options, unload it first
(`sudo modprobe -r v4l2loopback`) or reboot.

## Install

```bash
omarchy plugin add https://github.com/TomZandt/omarchy-decklink.git --enable
```

Plugins are added disabled so you can read the code first. Drop `--enable` to
review it before turning it on. Update with `omarchy plugin update tzv.decklink`.

## Configuration

Settings are saved to `~/.config/omarchy/decklink.conf` by the panel. It is a
plain `KEY=VALUE` file that is parsed, never run as a script, and every value is
checked against the known choices.

| Key                   | Default | Meaning |
|-----------------------|---------|---------|
| `DECKLINK_DEVICE`     | `0`     | Card number (the panel shows a Card dropdown when you have more than one) |
| `DECKLINK_CONNECTION` | `auto`  | `auto`, `hdmi`, `sdi`, `component`, `composite`, `svideo` |
| `DECKLINK_MODE`       | `auto`  | Video mode, e.g. `1080i50`, `1080p25`, `720p50` |
| `DECKLINK_PROFILE`    | `default` | Sub-device / duplex layout, Duo 2, Quad 2 and 8K Pro only: `one-sub-device-full`, `one-sub-device-half`, `two-sub-devices-full`, `two-sub-devices-half`, `four-sub-devices-half` |
| `DECKLINK_FORMAT`     | `auto`  | `auto`, `8bit-yuv`, `10bit-yuv`, `8bit-argb`, `8bit-bgra`, `10bit-rgb` |
| `DECKLINK_SINK`       | auto    | Loopback device to write to (`/dev/videoN`); normally found by label |

The bar plugin also has one shell setting, `refreshIntervalSec` (default 5):
how often the bar polls the status.

## Other DeckLink models

From [Blackmagic's model list](https://www.blackmagicdesign.com/products/decklink/models).
"Capture" cards work as a webcam source; "playback" cards can't.

| Model | Capture inputs | Pixel formats (Blackmagic specs) | Status |
|-------|----------------|----------------------------------|--------|
| **Mini Recorder (HD)** | 3G-SDI, HDMI | YUV 4:2:2 8/10-bit, RGB | **Tested** |
| Mini Recorder 4K | 6G-SDI, HDMI 2.0a | YUV 4:2:2 8/10-bit, RGB | Untested |
| Micro Recorder | HD-SDI or HDMI (add-on connectors) | YUV 4:2:2 8/10-bit | Untested |
| SDI Micro | 3G-SDI | YUV 4:2:2 8/10-bit, RGB | Untested |
| SDI 4K | 6G-SDI | YUV 4:2:2 10-bit, RGB | Untested |
| Studio 4K | SDI, HDMI, component, composite, S-Video | YUV 4:2:2 8/10-bit, RGB | Untested |
| 4K Extreme 12G | 12G-SDI, HDMI, component, composite, S-Video, optical (optional) | YUV 4:2:2 8/10-bit, RGB | Untested |
| Quad HDMI Recorder | 4× HDMI 2.0b | YUV 4:2:2 8/10-bit, RGB | Untested |
| Duo 2, Duo 2 Mini | 4× 3G-SDI | YUV 4:2:2 8/10-bit, RGB | Untested, see profiles |
| Quad 2 | 8× 3G-SDI | YUV 4:2:2 8/10-bit, RGB | Untested, see profiles |
| 8K Pro Mini | 4× 12G-SDI | YUV 4:2:2 8/10-bit, RGB | Untested, see profiles |
| 8K Pro G2 | 4× 12G-SDI, HDMI 2.1 | YUV 4:2:2 8/10-bit, RGB | Untested, see profiles |
| Mini Monitor 4K / HD | none (playback only) | n/a | **Won't work** |

The card list, inputs and pixel formats follow Blackmagic's
[technical specifications](https://www.blackmagicdesign.com/products/decklink/techspecs/W-DLK-39).

The panel adapts to the selected card:

- **Modes** are filtered to what the card itself reports to GStreamer
  (`gst-device-monitor-1.0 Video/Source`), so a Mini Recorder only offers SD,
  1080 up to 30p/60i and 720p, while a 4K card also offers the 2160 modes.
  If the card can't be queried, every mode is shown.
- **Connections** are filtered by model name using the table above (SDI and
  HDMI for the recorders, analog inputs for the Studio 4K and 4K Extreme 12G,
  optical SDI for the 4K Extreme 12G only, HDMI only for the Quad HDMI
  Recorder). An unrecognised model shows every connection.
- **Pixel formats** follow the tech specs: YUV only for the Micro Recorder,
  YUV and RGB for the rest. An unrecognised model shows every format.
- **Card** is a dropdown that appears when GStreamer sees more than one card.
  Changing it reloads the other dropdowns for that card.
- **Sub-device profile** appears only for the Duo 2, Quad 2 and 8K Pro.

Things to know on other cards:

- **Mode:** pick a mode your source sends. A wrong mode streams black, and the
  icon switches to the no-signal colour.
- **4K and 8K:** the pipeline converts every frame to YUY2 and may deinterlace
  on the CPU, which is heavy at those sizes. 4K DCI and 8K modes are not offered.
- **Pixel format:** RGB formats have limits that depend on the mode (for
  example RGB up to 1080p30 on the Mini Recorder HD over SDI). If a mode shows no
  picture in RGB, use 10-bit or 8-bit YUV.
- **Find your card's modes:** `gst-inspect-1.0 decklinkvideosrc` and
  `gst-device-monitor-1.0 Video/Source`.

If you try another model, please open an issue with the model, what worked and
what didn't, so this table can be updated.

## How it works

`backend.sh` runs a GStreamer pipeline
(`decklinkvideosrc ! videoconvert ! deinterlace ! v4l2sink`) as a transient
systemd user unit called `tzv-decklink`. Nothing is installed or enabled by the
plugin, and nothing runs as root. The QML calls only `backend.sh` and holds no
knowledge of the card; the lists of choices live in `backend.sh options`. Signal
state comes from the pipeline's own "Signal lost / recovered" log lines.

### What it runs

`backend.sh` runs `systemd-run --user`, `systemctl --user`, `journalctl --user`,
`gst-launch-1.0`, `gst-device-monitor-1.0`, `pgrep` and `notify-send`. The only
file it writes is `~/.config/omarchy/decklink.conf` (plus a `.lock` beside it).

## Removal

```bash
systemctl --user stop tzv-decklink     # if the camera is running
omarchy plugin remove tzv.decklink
rm -f ~/.config/omarchy/decklink.conf ~/.config/omarchy/decklink.conf.lock
```

Optionally remove the virtual camera setup:

```bash
sudo rm /etc/modprobe.d/v4l2loopback.conf /etc/modules-load.d/v4l2loopback.conf
```

## Development

```bash
omarchy plugin validate .
bash tests/backend.test.sh     # needs no card, systemd or desktop
```

## License

MIT, see [LICENSE](LICENSE).
