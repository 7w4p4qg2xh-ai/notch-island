# Security Policy

## Scope

Notch Island is an unofficial fork of Boring Notch. It has no security team and
no response-time guarantee. This policy exists so that reporters do not send
findings to the wrong project.

## Reporting a Vulnerability

**If the issue also affects upstream Boring Notch** (most of the notification and
XPC code originates there), report it to
[The Bored Team](https://github.com/TheBoredTeam/boring.notch/security/advisories/new).
They know their code better, and a fix there benefits both projects.

**If the issue is specific to this fork** — the Liquid Glass renderer, backdrop
luminance sampling, floating-island geometry, or the lyric fetch changes — use
the Security Advisory tab of this repository:

    Security -> Advisories -> Report a vulnerability

Please include the macOS version, the permission state (Screen Recording,
Accessibility), and whether the app was installed in `/Applications` or run from
Xcode.

## What this app can access

Be aware before installing, because the design requires broad permissions:

| Permission | Why | Where it is used |
|---|---|---|
| Screen Recording | Samples a downsampled 192x108 region to measure backdrop brightness | `BackdropLuminance` in `NotchShape.swift` |
| Accessibility | Reads notification banner text through the XPC helper | `NotificationWatcher.swift` |
| Apple Events (Music, Spotify) | Reads the current track and playback position | `LyricsService`, media controllers |
| Microphone / audio capture | Optional live waveform for the music view | `AudioCaptureManager` |

The backdrop sample is read into memory, averaged, and discarded. It is never
written to disk or transmitted. No telemetry, no analytics, no network calls
beyond the lyric providers (LRCLIB, NetEase) when a song is playing.

## Supported versions

`main` only. There are no releases and no backports.
