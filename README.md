# Headroom

A tiny macOS menu bar app that tells you if your Mac is fast or slow right now, and which apps are to blame.

![Headroom in light and dark mode](screenshots/headroom-light-dark.png)

## What it shows

- A status line: running smoothly, a bit busy, or slowing down, plus the reason. It goes by macOS's own memory pressure level, whether swap is growing, and whether CPU stays high for 30 seconds.
- Memory, CPU and swap, each with a graph of the last 15 minutes.
- The apps using the most memory or CPU, with helper processes counted under their app. Hover a row to quit the app.
- Docker containers, if Docker is running, grouped by compose project. Hover to stop or start them. When the Docker VM holds a lot more memory than its containers use, Headroom offers to restart Docker, then starts your containers again.

The menu bar icon is a gauge. It turns orange when your Mac is busy and red when it's slow.

## Performance

- Headroom doesn't run `top`, `ps` or the `docker` CLI. It reads app numbers from libproc and asks Docker's API socket for the rest.
- With the menu closed, it reads a few kernel counters every 5 seconds: about 15 MB of memory and close to 0% CPU.
- With the menu open, it checks apps every 2 seconds and Docker every 4 seconds. That's about 25 MB and around 1% of one CPU core.

## Install

Needs macOS 14 or later and the Xcode command line tools.

```sh
git clone https://github.com/julioest/headroom.git
cd headroom
./build.sh
open Headroom.app
```

To start it at login, add `Headroom.app` in System Settings > General > Login Items.

## Notes

- Processes owned by other users, like WindowServer and system services, aren't listed. macOS doesn't let a regular app read them, and you can't quit them anyway.
- Docker support expects Docker Desktop at `/Applications/Docker.app`, with its socket at `~/.docker/run/docker.sock`.
- The build is ad hoc signed, so it's meant to run on the Mac you build it on.

## License

MIT
