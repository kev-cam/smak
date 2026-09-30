# smak-buildtest baseline, 2026-09-27

Produced with `smak-buildtest` (see buildtest/README.md) in podman containers.
Only Ubuntu mirrors were reachable from the machine that ran this, so the
Debian, Fedora, openSUSE, Arch and Alpine images are supported by the harness
but were not exercised here.

| file | what |
|------|------|
| ubuntu24-before-fixes.md | all projects, smak at ad37619 (before this branch's fixes) |
| ubuntu24-after-fixes.md | all projects with the fixes; an earlier harness still warned on cosmetic command-print differences |
| ubuntu22-after-fixes.md | dnsmasq, dnsmasq-full, htop, tmux, zlib on Ubuntu 22.04 |
| ubuntu24-dnsmasq-htop-final.md | dnsmasq, dnsmasq-full, htop with the final harness |

Open problems these runs found are listed in docs/bugs.md (entries marked
"smak-buildtest").
