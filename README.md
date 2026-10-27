# elasticsearch-synology

Elasticsearch 9 Docker images patched to run on **Synology DSM**, whose kernel
(4.4.302+ on DSM 7.x) is built without seccomp.

## Why

Since 8.0, Elasticsearch always installs a seccomp system call filter, and the
`bootstrap.system_call_filter` setting is gone. On a kernel without
`CONFIG_SECCOMP`, stock ES 9 exits at boot:

```
java.lang.UnsupportedOperationException: seccomp unavailable: CONFIG_SECCOMP not compiled into kernel,
CONFIG_SECCOMP and CONFIG_SECCOMP_FILTER are needed
```

You can't fix this from settings or the container's options, and patching the
DSM kernel isn't practical.

## What the patch does

The `Dockerfile` starts from the official image, downloads the two matching
source files for that exact version, patches them, compiles them with the
bundled JDK, and swaps them into the jars:

1. **`LinuxNativeAccess.tryInstallExecSandbox`**: when the kernel can't install
   the filter, it logs this warning instead of crashing:
   `system call filter not installed (patched for kernels without seccomp)`.
2. **`BootstrapChecks`**: drops `SystemCallFilterCheck`. Without this, any
   multi-node cluster (where bootstrap checks are enforced) refuses to start.

Each patch is guarded by a `grep -c ... = 1` check. If a future Elasticsearch
release changes that code, the build fails instead of producing a broken image.

Tested on a DS1823xs+ (DSM 7.3.2, kernel 4.4.302+) with 9.5.5, both single-node
and in a 2-node hot/warm cluster with Kibana, Fleet, Logstash and EDOT.

## Security trade-off

Without seccomp, Elasticsearch has no exec sandbox: a bug that let someone run
code inside ES would no longer be stopped from starting other programs. Keep the
node on your LAN behind authentication, and **don't expose it to the internet**.

## Build

```sh
./build.sh            # newest stable 9.x
./build.sh 9.5.5      # a specific version
./build.sh --no-test  # skip the smoke test
```

`build.sh` builds `elasticsearch-synology:<version>`, then boots a throwaway
single-node container, indexes a document and searches for it. On a kernel
without seccomp, it also checks that the patched warning was logged. It works
with Container Manager's legacy builder; buildx isn't needed.

Or build directly:
`docker build --build-arg ES_VERSION=9.5.5 -t elasticsearch-synology:9.5.5 .`

No prebuilt image is published; build it on your own machine. The GitHub
Actions workflow (`.github/workflows/build.yml`) builds and tests the newest 9.x
release every day, so a release that breaks the patch shows up as a failed check.

## Running it

See `docker-compose.example.yml` for a single node in Container Manager.

### Things you'll hit on a Synology

- **`vm.max_map_count`** is 65530 by default, and Elasticsearch wants 262144.
  - **No host change:** set `node.store.allow_mmap: false`. This also skips that
    bootstrap check. It's a bit slower.
  - **Faster:** add a DSM boot task (Control Panel → Task Scheduler → Triggered
    Task → Boot-up, user root) that runs `sysctl -w vm.max_map_count=262144`.
- **Share ACLs reject unknown uids.** The image runs as uid 1000, which a
  Synology share's ACL denies even when the folder looks like `rwxrwxrwx+`. Run
  the container as your NAS user with gid 0, e.g. `user: "1026:0"` (find your
  uid with `id -u`). The Elasticsearch and Kibana images support this. Logstash
  then needs its `logstash.yml` mounted read-only, because its entrypoint
  rewrites that file and fails as a different uid.
- **Keep master-eligible nodes on SSD/NVMe.** On an HDD RAID6 volume, fsync took
  about 0.9 s, so every cluster-state update on a master node there timed out
  after 30 s. HDD is fine for warm or cold data-only nodes.
- **Containers on several Docker networks** can advertise the wrong address to
  the rest of the cluster. Give the cluster network a fixed subnet and set
  `network.publish_host` on each node.

## License

The patched files come from Elasticsearch's source, which is available under
AGPLv3, SSPL or the Elastic License 2.0. You can only use or share these images
under the terms of one of those licenses; this repo's own scripts add no extra
restrictions.
