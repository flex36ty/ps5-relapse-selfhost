# PS5 Relapse Exploit
Supported firmware: 7.00 through 13.60.

## Stability notes
Webkit may need several attempts, reload the page if the browser stalls. The kernel exploit may hang or panic the console, so reboot before trying again if that happens.

## Debian / Ubuntu container setup

Upload this entire project, including `setup-ps5.sh`, `serve.py`, and
`serve_https.py`, to the container. Stop any manually running Python web servers
with Ctrl+C first. From the uploaded project directory, run as root:

```bash
bash setup-ps5.sh 192.168.0.23
```

Replace the IP with the container's LAN address. The script copies the web files
to `/home/ps5` (or uses them in place when already there), installs dnsmasq,
creates a self-signed certificate, and enables HTTP/HTTPS systemd services.
It directs `manuals.playstation.net` to the container. Other DNS queries use
Cloudflare and Quad9; this is not an update-blocking DNS configuration.
Existing overwritten files are backed up under `/var/backups/ps5-host`.
Existing additional files are not deleted. Rerunning updates the installation.

Set the PS5 primary DNS to the container's IP and open User's Guide. Accept the
local certificate warning if offered. Reserve the IP in your router or use a
static address. If firewalls are enabled, allow your LAN to reach TCP/UDP 53
and TCP 80/443; the script does not change Proxmox or container firewall rules.

```bash
systemctl status dnsmasq ps5-http ps5-https
journalctl -u ps5-https -u ps5-http -u dnsmasq -f
```

Certificates last one year; rerun setup within the final week to renew them.

## Exploit chain
Browser stage uses JSC info leaks and a structured clone object pool mismatch to corrupt a typedarray. The kernel stage combines a address leak with an `aio_multi_wait` uaf race to establish kernel r/w.

## Credits
ntfargo, ufm42, Sonic-Iso, Jordy, Dr. Yenyen, TheFlow, SlidyBat,  Flatz, cow, nhk, bollarz, Sleirsgoevy, EchoStretch, EarthOnion.

## Disclaimer
This project is intended for **educational and security research purposes only**. It does not endorse piracy, unauthorized access, or misuse of commercial devices. Use it only on devices you own or are authorized to test, and comply with applicable laws and regulations.

The software is provided as-is, without warranty. You assume the risks of using it, including system instability, data loss, and account bans. The maintainers accept no liability for resulting damage. 
