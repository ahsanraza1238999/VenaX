# VenaX — Plug-and-Play Local AI Server

Turn any spare PC into a self-contained AI server: boot from USB, connect
to Wi-Fi (or just plug in Ethernet), and every device on the same network
gets a private ChatGPT-style web UI backed by Ollama — no cloud, no account,
no internet dependency once the model is downloaded.

## What was added on top of your original build-iso.sh

Your original script already did the hard part (Debian rootfs, Ollama
install, a basic chat page, the `wifi` tool, mDNS, firewall). This version
adds the "plug and play" layer around it:

| Feature | How |
|---|---|
| Hardware detection | `venax-detect-hardware` reads `/proc` + `lspci` at boot, writes `/var/lib/venax/hardware.json` |
| Model suggestions | `model_catalog.py` maps detected RAM to a shortlist of Ollama models that will actually run well |
| One-click model download | Web UI **Models** tab, with a live progress bar (streamed from Ollama's `/api/pull`) |
| System usage | Web UI **System** tab — RAM, load average, disk free, uptime, refreshed every 4s |
| Share URL | Web UI **Connect** tab shows the LAN URL + `venax.local` + the raw Ollama API URL |
| Auto-login | Console auto-logs in as `venax` so the startup banner runs with zero typing |
| Model persistence | Optional `VENAXDATA` partition — if present, downloaded models survive a reboot instead of living only in RAM |
| CLI parity | `venax-models` lets you download a suggested model from the console too, no browser needed |

## Boot flow

1. **Plug in USB, boot.** GRUB has a normal entry and a "with persistence" entry.
2. **Auto-login as `venax`** (password `venax` if you ever need it over SSH/console).
3. `venax-startup` runs automatically:
   - If Ethernet is already up, it skips straight to services.
   - If not connected, it launches the `wifi` tool: pick a network, type
     the password, done.
4. In parallel/after, systemd brings up, in order: `venax-persist` (mounts
   `VENAXDATA` if present) → `venax-detect-hardware` (writes the hardware
   profile) → `ollama` → `venax-web`.
5. The console prints the LAN URL, the top suggested models for *this*
   machine, and whether persistence is on.
6. Anyone on the same Wi-Fi/Ethernet opens `http://venax.local:8080` (or
   the printed IP) and gets the full web UI: **Chat / Models / System /
   Connect**.

## Enabling model persistence (optional but recommended)

Without this, VenaX runs entirely from RAM (standard live-boot behavior):
fast and disposable, but every downloaded model is gone on reboot.

To make models persistent, add a second partition to the USB stick (or use
a second USB drive) formatted ext4 and labeled `VENAXDATA`:

```bash
# WARNING: destructive — check the device name with lsblk first
sudo mkfs.ext4 -L VENAXDATA /dev/sdX2
```

Boot with the "VenaX (with persistence)" GRUB entry. `venax-persist`
detects the label automatically, mounts it at `/mnt/venax-data`, and points
Ollama's `OLLAMA_MODELS` at it — no other configuration needed. Give it
enough space for whatever models you plan to keep (models range roughly
0.4 GB to 40+ GB — see the catalog below).

## Model catalog / suggestion logic

`model_catalog.py` (`/usr/local/lib/venax-web/model_catalog.py` in the
image) is a hand-picked list of Ollama models tagged with an approximate
minimum RAM. `suggestions_for(ram_gb)` returns the largest models that
should comfortably fit, plus the smallest catalog entry as a guaranteed
fallback. Edit this file (and rerun the build) to change what gets
suggested — e.g. add your own fine-tunes or swap in newer model tags.

This build does **not** install GPU drivers, so inference is CPU-only even
if an NVIDIA/AMD GPU is detected (the hardware page will still show it, for
your information, and note it's not accelerated). Adding real GPU
acceleration is a natural next step — see "Future work" below.

## Web UI tabs

- **Chat** — pick an installed model, chat, responses stream token by token.
- **Models** — suggested models for this machine with a Download button and
  progress bar; installed models listed separately.
- **System** — live RAM/CPU-load/disk/uptime, plus the static hardware
  summary (CPU, RAM, detected GPU, tier).
- **Connect** — the URLs to hand to someone else on the network.

All of this talks to Ollama's normal REST API (`/api/generate`,
`/api/pull`, `/api/tags`, `/api/ps`, `/api/delete`, ...), which
`venax-web`'s `server.py` transparently proxies and streams — any other
Ollama-compatible client (mobile app, another script) can also just point
at `http://<server-ip>:11434` directly.

## Useful commands (on the server console)

```
venax-status      full status: network, services, hardware, models
venax-models      download a suggested model from the console
wifi              (re)connect to Wi-Fi
ollama list       installed models
ollama run <tag>  chat with a model directly in the terminal
```

## Building

Same as before:

```bash
chmod +x build-iso.sh
./build-iso.sh
```

Needs `debootstrap`, `grub-mkrescue`, `mksquashfs`, `sudo`, and internet
access on the *build* machine (it pulls Debian + Ollama during the build,
not at boot time). Output ISO lands in `output/`.

```bash
sudo dd if=output/VenaX-0.1.0-x86_64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

## Future work (not in this version)

- **GPU acceleration**: install NVIDIA/AMD drivers + CUDA/ROCm runtime in
  the rootfs and set `OLLAMA_*` GPU env vars; hardware detection already
  identifies the GPU vendor, so `gpu_accelerated` just needs to flip to
  `true` and the suggestion tiers can be raised accordingly.
- **HTTPS / auth**: the web UI and Ollama API are open on the LAN with no
  login — fine for a trusted home/office network, not for anything more
  exposed. Add a reverse proxy (Caddy/nginx) with a login page if you want
  access control.
- **Multi-user chat history**: currently each browser session is
  stateless (Ollama itself keeps no chat history across requests); could
  add per-device conversation storage in the web UI.
