# Containerised Cumulus VX images

## Cumulus VX image

This is a containerised Cumulus VX image. 

#### Building

To build the latest stable CL version run: 

```
make build
```

To build an older version of CL, e.g. 4.3.0 run:

```
TAG=4.3.0 make build
```


#### Running

```
docker run -d --name cumulus --privileged networkop/cx:4.4.0
```


#### Testing

```
make test                      # static + runtime
make test-static               # offline checks only
make test-runtime              # boots systemd, checks services
```

The suite is split in two because of a hard constraint:

* **static** tests inspect the built image without booting it (package
  consistency, required binaries, container hacks, apt pinning). These run
  anywhere, including amd64-under-emulation on Apple Silicon.
* **runtime** tests boot `/sbin/init` and check that sshd/FRR/NVUE actually come
  up. These need a **native amd64 host** - under qemu-user emulation systemd
  starts but `systemctl` cannot reach it (`Transport endpoint is not
  connected`), because credential passing over its private socket does not
  survive emulation. `tests/run.sh` detects this and skips them; CI runs them on
  `ubuntu-latest`.

Note that Cumulus 5.x has no NCLU (`net`) binary, so with
[netlab](https://github.com/ipspace/netlab) this image must be used as device
type `cumulus_nvue` (NVUE / `nv` commands), not `cumulus`.

The image enables a **mgmt VRF** by default, so the host kernel must provide
`vrf.ko`. On Ubuntu it lives in `linux-modules-extra`, which minimal cloud/VM
kernels often omit:

```
sudo apt install -y linux-modules-extra-$(uname -r)
sudo modprobe vrf
```

Without it `ifreload -a` fails with `mgmt: create failed ... Operation not
supported` and `ntpsec@mgmt.service` enters a failed state. `tests/runtime.sh`
detects this and skips the affected check rather than reporting a bogus failure.

## Host image

This image is intended to be used to simulate servers. It accepts an optional integer argument that will tell the [entrypoint script](host/entrypoint.sh) to wait until that number of interfaces are connected:

#### Building 


```
cd host && docker build -t networkop/host:ifreload .
```

#### Running

Do not wait for extra interfaces to be connected:

```
docker run -d --name host --privileged networkop/host:ifreload
```

Wait for 2 extra interfaces to be connected (in addition to the default eth0):

```
docker run -d --name host --privileged networkop/host:ifreload 3
``` 


