# DeckLink

Use a Blackmagic DeckLink capture card as a webcam, from the
[Omarchy](https://omarchy.org) bar. Start and stop the virtual camera with a
click, and pick the input connection, video mode and pixel format from a panel.
Chrome, Firefox, Zoom and anything else that speaks V4L2 sees it as
"DeckLink Virtual Camera".

DeckLink is an unofficial community plugin. It is not affiliated with,
endorsed by, or connected to Blackmagic Design or Omarchy.

## It never starts by itself

A DeckLink card serves one app at a time. While this plugin's camera is
running, OBS or DaVinci Resolve can't open the card, and the other way round.
So the camera only runs when you start it, and stopping it hands the card
straight back. If OBS or Resolve is running, the tooltip warns you that it may
be holding the card.

## Click map

| Click  | Action                                  |
|--------|-----------------------------------------|
| Left   | Open the settings panel                 |
| Right  | Start / stop the camera                 |
| Middle | Refresh the status                      |

The icon shows the state: dimmed when off, normal when live, and in the alert
colour when the camera is running but there is **no signal** (it streams black).
In the panel, `S` toggles the camera and `R` refreshes.

## How it works

`backend.sh` runs a GStreamer pipeline
(`decklinkvideosrc ! videoconvert ! deinterlace ! v4l2sink`) as a transient
systemd user unit called `tzv-decklink`. Nothing is installed or enabled, and
nothing runs as root. Settings are saved to `~/.config/omarchy/decklink.conf`.
Signal state comes from the pipeline's own "Signal lost / recovered" log lines.

## Requirements

- Omarchy with the Quickshell shell (`omarchy-shell`)
- Blackmagic Desktop Video drivers (the `blackmagic_io` kernel module)
- GStreamer with the DeckLink plugin: `gst-plugins-bad`
- `v4l2loopback`, loaded with a labelled device. Copy
  [system/v4l2loopback.conf](system/v4l2loopback.conf) to
  `/etc/modprobe.d/v4l2loopback.conf`, then `sudo modprobe v4l2loopback`
  (or reboot). The plugin finds the device by its "DeckLink Virtual Camera"
  label, falling back to `/dev/video0`.

## Install

```bash
omarchy plugin add https://github.com/TomZandt/omarchy-decklink.git --enable
```

Plugins are added disabled so you can read the code first. Drop `--enable` to
review it before turning it on. Update with `omarchy plugin update tzv.decklink`.

## What it runs

`backend.sh` runs `systemd-run --user`, `systemctl --user`, `journalctl --user`,
`gst-launch-1.0`, `pgrep` and `notify-send`, and writes only
`~/.config/omarchy/decklink.conf`. The QML runs only `backend.sh`.

## Settings

| Key                  | Default | Meaning                              |
|----------------------|---------|--------------------------------------|
| `refreshIntervalSec` | 5       | How often the bar polls the status   |

Advanced overrides can go in `decklink.conf`: `DECKLINK_DEVICE` (card number,
default 0) and `DECKLINK_SINK` (loopback device, default auto-detected).

## License

MIT, see [LICENSE](LICENSE).
