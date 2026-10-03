# Headroom

[![Latest release](https://img.shields.io/github/v/release/julioest/headroom)](https://github.com/julioest/headroom/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A tiny macOS menu bar app that tells you if your Mac is fast or slow right now, and which apps are to blame.

![Headroom in light and dark mode](screenshots/headroom-light-dark.png)

## What it shows

- **Status line:** *Running smoothly*, *A bit busy* or *Slowing down*, plus the reason. It goes by macOS's own memory pressure level, whether swap is growing, and whether CPU stays high for 30 seconds.
- **Memory, CPU and swap:** each with a graph of the last 15 minutes.
- **Top apps:** the apps using the most memory or CPU, with helper processes counted under their app. Hover a row to quit the app.
- **Docker:** containers grouped by compose project, if Docker is running. Hover to stop or start them. When the Docker VM holds a lot more memory than its containers use, Headroom offers to restart Docker, then starts your containers again.

The menu bar icon is a gauge. It turns orange when your Mac is busy and red when it's slow.

## Performance

Headroom doesn't run `top`, `ps` or the `docker` CLI. It reads app numbers from `libproc` and asks Docker's API socket for the rest.

| Menu | Checks | Memory | CPU |
|---|---|---|---|
| Closed | a few kernel counters every 5 s | ~15 MB | ~0% |
| Open | apps every 2 s, Docker every 4 s | ~25 MB | ~1% of one core |

## Install

Download the `.dmg` from the [latest release](https://github.com/julioest/headroom/releases/latest), open it and drag **Headroom** to **Applications**. Needs **macOS 14 or later**, on Apple Silicon or Intel.

Headroom isn't signed with an Apple Developer ID yet, so macOS blocks it the first time:

1. Open Headroom. macOS says it can't verify the app. Click **Done**.
2. Go to **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to the Headroom message.
3. Open Headroom again and confirm.

Or clear the block from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Headroom.app
```

To start it at login, add Headroom in **System Settings › General › Login Items**.

### Build from source

Needs the Xcode command line tools.

```sh
git clone https://github.com/julioest/headroom.git
cd headroom
./build.sh
open Headroom.app
```

`./release.sh 0.1.0` builds the universal app and packages the `.dmg` and `.zip` into `dist/`.

## Notes

- Processes owned by other users, like `WindowServer` and system services, aren't listed. macOS doesn't let a regular app read them, and you can't quit them anyway.
- Docker support expects Docker Desktop at `/Applications/Docker.app`, with its socket at `~/.docker/run/docker.sock`.

## License

[MIT](LICENSE)
