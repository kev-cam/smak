# smak-buildtest: build real projects with smak in containers

`smak-buildtest` fetches make/cmake projects from GitHub and builds each one
with plain `make` as the reference, then with smak in several modes. Every
build runs inside a container, so the same test runs on any Linux distro.
Podman is the default engine; Docker works as a fallback (`--engine docker`).

```
smak-buildtest run dnsmasq                        # one project, default modes
smak-buildtest --modes seq,par,server,multi run all
smak-buildtest --distro ubuntu,ubuntu22 run dnsmasq lua
smak-buildtest run https://github.com/htop-dev/htop   # any repo, ad hoc
smak-buildtest add owner/repo configure=--disable-docs  # keep it in your list
smak-buildtest report                             # summary of the last run
```

## Modes

| mode     | what runs                                                        |
|----------|------------------------------------------------------------------|
| `seq`    | `smak` (one process)                                             |
| `par`    | `smak -jN`                                                       |
| `server` | `smak -cli -jN`, `build`, `detach`; later builds through `smak-attach -pid PID` against the surviving job server; finally `smak-attach --kill-all` |
| `multi`  | `smak -jN --ssh=node1:K,node2:K --local-workers=L --cd=...` with worker containers acting as separate machines |
| `interp` | cmake projects only: `smak -cmake-interp-only` interprets CMakeLists.txt itself, then `smak -jN` |

Each mode starts from the same configured tree, at the same path, and is
checked for:

- **Exit status.** A CLI session counts as failed unless it prints "Build succeeded".
- **Artifacts.** Every file make wrote must be written. Extra files are a warning.
- **Same build.** smak's compile commands are compared with make's, and final binaries and libraries are checksummed. Different commands with different binaries fails the mode, since smak built something else. make builds the project twice, and binaries that differ between its own two builds (e.g. built with `-coverage`) are not compared.
- **Nothing left undone.** A follow-up `make` must find nothing to do. Anything make also redoes on an up-to-date tree is ignored as noise.
- **No-op rebuild.** Running smak again must rebuild nothing, or the mode gets a warning.
- **Incremental rebuild.** Touching one source must rebuild its object and relink.
- **Job placement.** In multi mode, compiler wrappers on the shared volume record which host ran each compile. The mode fails if the worker nodes ran nothing.
- **Leaked processes.** smak servers or workers still running after a mode are reported and killed.

smak builds get a timeout of six times the make build time plus a minute,
at least three minutes, so a hang costs minutes rather than the whole run.

## Configure failures and automatic packages

When bootstrap, configure or the reference make build fails, `bt-run`
reads the log for what is missing and installs the matching package, then
retries from a clean tree, up to ten rounds:

| log line | key |
|----------|-----|
| `Package 'x' ... not found`, `No package 'x' found`, `checking for x >= 1.2... no` | `pc:x` |
| `fatal error: foo/bar.h: No such file or directory` | `h:foo/bar.h` |
| `x: command not found`, `WARNING: 'x' is missing on your system` | `bin:x` |
| `cannot find -lx` | `lib:x` |
| `Could NOT find X`, `...provided by "X"` | `cmake:X` |
| `possibly undefined macro: AX_...` | `m4:AX_` |
| `configure: error: libevent not found` | `any:libevent` (tries pc, lib, header, program) |

Keys are looked up in `pkgmap.txt` first. Unmapped keys fall back to the
distro's own lookup:

- **Debian/Ubuntu:** `apt-file`
- **Fedora/openSUSE:** `pkgconfig(x)`, `cmake(X)` and file-path capabilities
- **Arch:** `pacman -F`
- **Alpine:** `pc:` and `cmd:` names

Installed packages are listed in the report, and in multi mode they are
installed on the worker nodes too. Use `--no-autopkg` to see raw failures.

## Distros

Aliases: `ubuntu` (24.04), `ubuntu22`, `debian`, `fedora`, `tumbleweed`,
`arch`, `alpine`. Any image reference also works, e.g.
`--distro docker.io/library/debian:13`. Images are built once as
`localhost/smak-bt-<alias>` from `Containerfile` plus `bt-pkg base`. Rebuild
them with `smak-buildtest image` or `--rebuild-image`.

Behind a TLS-intercepting proxy, pass its CA with `--ca FILE`. Use
`--net host` when the package mirrors are only reachable through a proxy on
the host's loopback.

## Files

| file | role |
|------|------|
| `../smak-buildtest` | host driver: images, sources, containers, report |
| `bt-run` | in-container runner for one project; also `bt-run --report DIR` |
| `bt-pkg` | distro-neutral package install, base toolchain, CA and sshd setup |
| `bt-entry` | container entry point: `node` runs sshd, `head` runs bt-run |
| `projects.list` | curated projects and per-project options (format in the file header) |
| `pkgmap.txt` | missing-thing to package map per distro family |
| `Containerfile` | image recipe, `BASE` build argument selects the distro |

## Layout of a run

```
~/.cache/smak-buildtest/          (or $SMAK_BT_WORKDIR / --workdir)
  src/<project>/                  shallow clones, reused unless --refresh
  ssh/id_ed25519                  key the head uses to reach worker nodes
  projects.list                   projects you added with `add`
  runs/<id>/summary.md            the report
  runs/<id>/results/<distro>/<project>/result.json
  runs/<id>/results/<distro>/<project>/logs/{configure,reference,smak-*,verify-make,autopkg}.log
```

The smak checkout is mounted read-only at `/opt/smak` in every container.
The run therefore tests the working tree as it is, uncommitted changes included.

Because the checkout is mounted live, editing it while a run is in progress
mixes versions within that run. To keep working on smak during a long
batch, run it from a copy (`cp -a smak smak-snap; smak-snap/smak-buildtest ...`).

## Diagnosing a stalled build

A hung `-j` build can be inspected without restarting it:

```
kill -USR1 $(pgrep -x smak-server)     # inside the container, or on the host
cat /tmp/smak-jobmaster-<pid>.state
```

The state file lists the running jobs, every queued job with the status of
each of its dependencies, the connected sub-make relays with the targets they
still wait for, and pending composite targets. A relay whose outstanding
targets are all `done`, or a queued job waiting on a dependency that nothing
builds, points at the cause. Do not use `pkill -x smak-server` on a host that
runs a batch: container processes are visible there and it would stop their
servers too.
