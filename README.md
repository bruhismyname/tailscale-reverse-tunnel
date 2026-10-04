# tailscale-reverse-tunnel

SSH into a box you can't reach. Written for AI sandbox VMs (muse.ai and similar) that wipe `/etc` on every reboot, block inbound connections, and expect you to do everything through a chat window forever.

One script, three ways in:

```
                your VPS / sandbox
                can dial out · can't take inbound
                /etc gone after every reboot
                            │
            ┌───────────────┴────────────────┐
            │                                │
      reverse ssh -R                  pinggy TCP forward
            │                                │
      ┌─────▼──────┐                  ┌──────▼─────────┐
      │   your PC  │                  │ public address │
      │ (Tailscale)│                  │                │
      └────────────┘                  └────────────────┘
   ssh -p 2222 user@localhost      ssh -p NNNN user@host
   fixed address, works forever    works from anywhere,
                                   no Tailscale needed
```

If the sandbox happens to allow inbound, plain `ssh user@<tailscale-ip>` also works — the script just makes sure sshd is actually running first.

The script does the boring parts:

- Reinstalls and starts sshd after every VM reset (because nothing in `/etc` survives a reboot)
- Keeps the reverse tunnel to your PC alive, with backoff reconnect
- Opens a public TCP tunnel via Pinggy as fallback, and rotates it before the 60-minute free-tier cutoff so you never notice
- Refuses to expose SSH publicly until password login is off and at least one public key is registered
- Syncs `authorized_keys` to the real root home when the agent's `$HOME` points somewhere else (this happens, and it's maddening)
- Installs a 1-minute cron guard so the daemon comes back after a reboot
- Punches through HTTP CONNECT proxies when the sandbox only allows egress via proxy

## Quick start

On the VPS — paste the script anywhere, then:

```console
$ bash muse_tunnel.sh add-key "ssh-ed25519 AAAA… you@pc"
$ bash muse_tunnel.sh
```

On your PC — once:

```console
$ bash muse_tunnel.sh pc-info
```

That prints the two values the VPS needs (`PC_USER`, `PC_TAILSCALE_IP`). Put them in `~/workspace/tunnel/tunnel.env` on the VPS, make sure your PC runs an SSH server and Tailscale, then:

```console
$ ssh -p 2222 root@localhost
```

You're in. Route 2 turns itself on once password auth is off — run `bash muse_tunnel.sh url` on the VPS to get the public address.

## Commands

| Command | What it does |
|---|---|
| *(none)* | Install + start everything. Idempotent — safe to re-run |
| `status` | Full health check: daemon, sshd, both routes, cron |
| `url` | Print the exact SSH commands for each route |
| `add-key [KEY]` | Register a public key on the VPS |
| `diag` | Network diagnostics: proxy, Tailscale, Pinggy reachability, sshd |
| `start` / `stop` / `restart` | Control the guard daemon (`stop` also removes the cron) |
| `ensure` | One maintenance pass, no daemon |
| `cron-install` / `cron-remove` | Manage the 1-minute guard cron |
| `pc-setup` | Print the one-time setup steps for your PC |
| `pc-info` | Run **on the PC**: auto-detect username + Tailscale IP |

## Configuration

Everything lives in `~/workspace/tunnel/tunnel.env` (created on first run, never overwritten). The defaults are sane; the two you must set:

```bash
PC_USER="your-pc-username"
PC_TAILSCALE_IP="100.x.y.z"
```

Everything else — ports, forwards, Pinggy settings, check interval — has a working default. `PC_FORWARDS` takes a space-separated list if you want more than SSH (`"2222:127.0.0.1:22 8080:127.0.0.1:8080"`), first entry is the health-check port.

## How the guard works

There is one daemon, one cron line, no overlap:

```
cron (every 1 min) → muse_tunnel.sh start → is the daemon alive?
                                                │ yes → exit
                                                │ no  → start daemon
daemon (every 30 s) → restore packages → restore sshd → check tunnel → check pinggy
```

Old keeper scripts from previous setups (`pinggy-keeper`, `ssh-tunnel-keeper`, …) are detected and removed from cron automatically — they fight over the same ports and processes.

All state is in `~/workspace/tunnel`, the part of the disk that survives reboots. Everything the script rebuilds (`/etc/ssh`, packages, host keys) is treated as disposable.

## Security

- Password auth on the VPS gets turned off once a key exists. Public exposure (Pinggy) stays **off** until that happens — no exceptions.
- The reverse tunnel authenticates with a generated ed25519 keypair; the private key never leaves the VPS.
- Pinggy tokens are accepted via `tunnel.env` and never logged.
- Your PC's port 22 accepts the VPS key only — `PasswordAuthentication no` in the shipped config.

## Requirements

VPS: Debian-ish Linux with `apt`, `bash`, `python3`. Nothing else.

PC (for route 1): any SSH server + Tailscale. On Windows, the bundled config works with the sshd from Git for Windows — no admin rights, no Windows service needed.

## Honest limitations

- Route 1 needs your PC awake, Tailscale connected, and sshd running. Sleeping PC = no tunnel.
- Free Pinggy rotates the public address every 60 minutes. The guard rotates at minute 50 and writes the new address to `url` — but if you scripted against the address, it's on you to re-read it. A `PINGGY_TOKEN` (free account) gives you a fixed address.
- If the sandbox has no `crontab`, the guard runs as a plain daemon — it survives anything except a VM reboot, and after a reboot you need one `bash muse_tunnel.sh start` from the agent chat.
- One PC. Multiple PCs means multiple `PC_*` configs — not supported yet.

## License

MIT
