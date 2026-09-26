# Host build of this grok fork

This directory is the copy that matters. It is local to this fork and is **not
for an upstream pull request**. `local/host-ops` carries it, and `kitchensink`
merges that branch last so a rebuild does not drop the scripts.

An older copy still sits in `~/brain/docs/grok-build-update-cookbook.md` and
`~/brain/scripts/grok-build/`. That tree is read-only and already behind the
branch list. Do not follow it.

Upstream is <https://github.com/xai-org/grok-build>, a periodic export of xAI's
internal monorepo. It carries **no tags**. Pin by commit, not by version.

| what | where |
|---|---|
| checkout | the repo that contains this file (`host/`'s parent) |
| fork | `origin` = `git@github.com:csillag/grok-build.git` |
| upstream | `upstream` = `https://github.com/xai-org/grok-build.git` |
| deployed binary | `~/local/bin/grok` (a copy; previous kept as `grok.prev`) |
| scripts | `./host/` in this checkout |
| build logs | `~/grok-build-logs/` (`current.log` points at the latest run) |

`~/local/bin/grok-aoe` is the Agent of Empires wrapper. It is not part of this
build. This doc only names it.

## Branch layout

| branch | purpose | upstreamable |
|---|---|---|
| `main` | fast-forwards to `upstream/main`, then is pushed to `origin`. Never edited. | -- |
| `local/host-build-config` | drops the Armv9 `target-cpu` so the binary runs on this host | **no** |
| `fix/bwrap-absolute-path` | `GROK_BWRAP_PATH` pins the sandbox helper instead of a `PATH` lookup | yes |
| `feat/sandbox-env-paths` | `GROK_SANDBOX_READ_ONLY` / `GROK_SANDBOX_READ_WRITE` add directories to the sandbox profile at launch | yes |
| `feat/acp-session-steering` | advertises steering and handles `_session/steering`, so Agent of Empires can inject a follow-up into the running turn | yes |
| `local/host-ops` | this directory | **no** |
| `kitchensink` | throwaway merge of `host/branches.txt`, in that order. The only branch we build. | never |

Feature branches stay single-purpose. `kitchensink` is disposable and is
rebuilt from scratch every cycle. Never commit on it directly and never rebase
it.

The fork is public. Nothing secret goes on these branches.

`local/host-build-config` exists so a build needs no remembered environment.
Upstream pins `target-cpu=neoverse-v2` (Armv9, SVE2); this host is Cortex-A76
plus A55 (Armv8.2, no SVE). With the upstream flag the build succeeds and the
binary dies with SIGILL later. The branch drops the flag entirely rather than
using `native`, so the binary stays portable to the other arm64 machines.

To recreate the checkout:

```sh
git clone git@github.com:csillag/grok-build.git ~/local/src/grok-build
cd ~/local/src/grok-build
git remote add upstream https://github.com/xai-org/grok-build.git
git fetch upstream
git branch -f main upstream/main && git branch -u origin/main main
git push origin main
```

Topic branches are already on `origin`. `host/branches.txt` names them.

## The workflow

Read the topic-branch list the same way the rebuild does:

```sh
branches() {
    sed -e 's/#.*//' -e '/^[[:space:]]*$/d' host/branches.txt
}
```

Run that from the checkout root.

### 0. Check disk

Two heavy rustc jobs on this machine thrash. Look at disk before a clean
build, because a full home breaks every agent on the host:

```sh
df -h /home
du -sh target
```

If upstream moved a lot, or home is tight, delete `target` and build clean.
An incremental build keeps the old artifacts beside the new ones. The deployed
binary is a separate copy, so the tree is disposable.

### 1. Fetch upstream

```sh
git fetch upstream
git checkout main && git merge --ff-only upstream/main
git push origin main
git log -1 --format='%h %ad %s' --date=short
cat SOURCE_REV
git show main:crates/codegen/xai-grok-pager-bin/Cargo.toml | grep -m1 '^version'
```

`SOURCE_REV` names a commit in a repo we cannot see. The pin is the
`upstream/main` SHA.

### 2. Rebase each topic branch

One at a time, so a conflict belongs to one change:

```sh
git checkout main
for b in $(branches); do
    git checkout "$b" && git rebase main || break
done
```

Fix a conflict **on that branch** before moving on. Resolving it on
`kitchensink` is what makes the next cycle worse.

A clean rebase is not a correct one. On the rebuilt `kitchensink`, check that
each patch still does its job:

```sh
# active rustflags for this host must NOT mention target-cpu
awk '/^\[target\.aarch64-unknown-linux-gnu\]/{f=1;next} /^\[/{f=0} f && /^rustflags/' .cargo/config.toml

# the bwrap patch must still own the production spawn
grep -c 'fn bwrap_program()' crates/codegen/xai-grok-sandbox/src/lib.rs   # 1

# sandbox directory env vars
grep -n 'GROK_SANDBOX_READ_ONLY' crates/codegen/xai-grok-sandbox/src/profiles.rs

# steering is advertised and handled
grep -n '_session/steering' crates/codegen/xai-grok-shell/src/extensions/steer.rs
```

The upstream line that `local/host-build-config` replaces must still exist on
`main`. If upstream drops the Armv9 flag itself, delete that branch instead of
rebasing it.

### 3. Rebuild kitchensink

```sh
git checkout main
git branch -D kitchensink 2>/dev/null
git checkout -b kitchensink
for b in $(branches); do
    git merge --no-ff -m "kitchensink: merge $b" "$b" || break
done
```

`local/host-ops` is last in `host/branches.txt`, so this directory is in the
build branch.

### 3b. Push

Before building, so a lost checkout costs the build and nothing else:

```sh
git push --force-with-lease origin $(branches) kitchensink
```

`--force-with-lease` is expected. The rebase and the kitchensink rebuild
rewrite these branches every cycle. It still refuses if `origin` moved in a
way this checkout has not seen. Do not force-push `main`.

### 4. Build

```sh
setsid nohup ./host/run-build.sh >/dev/null 2>&1 &
./host/progress.sh
```

`run-build.sh` builds `-p xai-grok-pager-bin --release -j 6` under
`nice -n 19`, writes a per-run log, records the cargo pid in
`~/grok-build-logs/pids.txt`, and ends the log with `=== CARGO EXIT=<n> ===`.
`setsid` matters: a build started from an agent session otherwise dies with
the session and leaves no exit marker.

It clears `RUSTFLAGS` on purpose. An environment `RUSTFLAGS` replaces the
`.cargo/config.toml` target rustflags rather than adding to them.

Wait on the recorded pid, never on a process-name match:

```sh
P=$(awk '/^cargo pid/{print $3}' ~/grok-build-logs/pids.txt)
while kill -0 "$P" 2>/dev/null; do sleep 30; done
```

Expect one very large rustc at the end, near 10 GB. That shape is normal.
The build needs `protoc`. The distro `protobuf-compiler` satisfies it. Do not
install DotSlash. It downloads a prebuilt protoc, and prebuilt binaries are
not permitted here.

### 5. Deploy

```sh
./host/deploy.sh
```

It refuses unless the log ends in `CARGO EXIT=0` and `objdump` finds no SVE
instructions. It keeps the old binary as `~/local/bin/grok.prev` and installs
by copy-then-`mv`, so a grok already running keeps its old inode. New sessions
pick up the new binary on their next spawn. Rollback:
`mv -f ~/local/bin/grok.prev ~/local/bin/grok`.

Copy, never symlink, into `target/`. That tree must not be load-bearing for a
binary on `PATH`.

### 6. Smoke test

```sh
./host/smoke.sh
```

Spawns the deployed grok the way Agent of Empires does: `grok --sandbox
workspace agent stdio`, environment cleared to `PATH HOME TERM USER LANG`.
Pass: the first run prints `agentVersion`. The two bad `GROK_BWRAP_PATH` runs
are refused. `bwrap-path-good` points at `~/local/bin/bwrap`. That file has
been missing since the 2026-09-21 wipe, so that one run fails until a binary
is there again. The distro helper is `/usr/bin/bwrap`.

The script holds stdin open for 6 seconds after the request. Closing stdin at
once is a trap: if startup is slow, grok reaches EOF before it has
initialised, exits 0, and answers nothing. That looks like a broken sandbox.

### Provider speed

`./host/tokens-per-sec.sh` reads `shell.turn.inference_done` from
`~/.grok/logs/unified.jsonl`. That line is the after-the-call rate `main`
already computes. The script prints each session and a decode-time-weighted
total. Default window is 15 minutes. AoE grok processes share this log
because they bind-mount `~/.grok`.

### 7. Close out

Tell the Agent of Empires side the binary changed. Add a row to the record
below.

## Cautions

Never run `grok` without its own sandbox (`--sandbox workspace` or stricter).
The default profile is `off`, so the flag must be passed. `smoke.sh` always
passes it.

bwrap is chosen by `PATH` unless `GROK_BWRAP_PATH` is set. Under Agent of
Empires that variable has to be in the daemon's `environment` list, because
the daemon clears the environment before spawning agents.

Auto-update stays off: `auto_update = false` under `[cli]` in
`~/.grok/config.toml`. A run that leaves a prebuilt binary in
`~/.grok/downloads/` should have that file deleted.

There is no rustup here. `rust-toolchain.toml` is read by rustup, not cargo,
so the pin is ignored and the distro toolchain is used. A build that suddenly
fails on new syntax means upstream outran the distro rustc.

## Known issues

- A request read before stdin EOF is dropped if EOF arrives before the agent
  finishes starting. Harmless under Agent of Empires, which keeps stdin open,
  and handled in `smoke.sh`. Not patched here.
- A bad `GROK_BWRAP_PATH` always prints "refusing to fall back to a PATH
  lookup". For the `workspace` profile that is true. For a profile where bwrap
  is optional, grok then continues on Landlock alone, so the wording
  overstates it.

## Record of updates

| date | upstream `main` | version | build | notes |
|---|---|---|---|---|
| 2026-08-27 | `77cd7eb` | 1.0.10 | 43 min, first build | target-cpu via `RUSTFLAGS` |
| 2026-09-15 | `3794978` | 1.0.24 | 103 min, clean, nice 19 | kitchensink `ef908679`; smoke passed; cold-start EOF race found |
| 2026-09-23 | `07e35a3` | 1.0.41 | 74 min, clean, nice 19 | checkout recovered after the wipe; kitchensink `0077c5c3`; `bwrap-path-good` failed because `~/local/bin/bwrap` was gone |
| 2026-09-26 | `f0e3be11` | 1.0.41 | not a new compile | steering merged; rescue-identity commits rewritten; this directory added. Build branch before the host-ops merge was `2c4ac87e` |
