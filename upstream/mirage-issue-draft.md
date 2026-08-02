**Title:** Windows HVM `vif_ioemu` device never completes handshake — guest wedges (0.9.5, after #219)

Since the HVM fix in 0.9.5 (#219) a Windows HVM still cannot use qubes-mirage-firewall as its
netvm when the Xen PV network driver is installed: the guest burns ~2 CPU cores indefinitely
and never becomes reachable. Switching the same qube to a Linux netvm works immediately.

### Environment
- Qubes OS 4.3, Xen; qubes-mirage-firewall **0.9.5** (verified live: `qubes-firewall.xen`
  4320560 B, sha256 `2bfb49696e59a8ffbb660399e52bd82ffadbd02437d282eb8daab568b3261999`)
- Guest: Windows 10 22H2 standalone HVM, Qubes Windows Tools 4.2.2, Xen Project PV drivers
  9.1.0 (DriverVer 04/07/2025, vendor prefix `XP`)
- Reproduced with both stock QWT 4.2.2 and a locally rebuilt one; also on Windows 11 24H2.
  Also reproduced on 0.9.3, i.e. #219 did not change the outcome.

### Symptom
With the netvm set to mirage-firewall, from the moment the PV network driver binds:
~1.93–2.00 CPU cores consumed continuously (independent of vCPU count: 2.00 with 4 vCPUs,
1.95 with 2), qrexec never connects, ACPI shutdown is not serviced, the domain must be
destroyed. Detaching the netvm, or pointing it at a Linux netvm, restores the guest.

### Measured state during the hang
An HVM has two vifs. Guest domid 446, its stubdomain 447, netvm domid 427:

```
backend/vif/447/0  type = "vif"        state = "4"    <- stubdom vif: CONNECTED, works
backend/vif/446/0  type = "vif_ioemu"  state = "2"    <- guest PV vif: stuck at InitWait
/local/domain/446/device/vif/0/state = "5"            <- Windows frontend: CLOSING
both backends: hotplug-status=""  feature-sg=1 feature-rx-copy=1 feature-rx-notify=1
               feature-gso-tcpv4=0 feature-rx-flip=0 feature-smart-poll=0
```

Unikernel log for the same boot (both vifs are seen and threaded — #219 is working):

```
[dispatcher] add client vif {domid=443;device_id=0} with IP 10.137.0.64
[ethernet] Connected Ethernet interface fe:ff:ff:ff:ff:ff
[dispatcher] Client 443:0 (IP: 10.137.0.64) ready
[dispatcher] add client vif {domid=442;device_id=0} with IP 10.137.0.64
   ... (never becomes ready, never logs an error)
```

### Sequence
1. mirage sees both vifs and gives each its own thread (the #219 fix behaves as intended).
2. For the guest's `vif_ioemu` device it writes `InitWait` (2) and blocks in
   `read_frontend_configuration` waiting for the frontend to reach `Initialised|Connected`.
3. The Windows frontend never reaches `Initialised`. After xenvif's 120 s internal timeout it
   moves to `Closing` (5).
4. `lib/xenstore.ml` `read_frontend_configuration` treats `Closing`/`Closed` as "keep
   waiting" (the existing `(* XXX: stop waiting? *)` comment), so the backend remains at
   `InitWait` forever and the frontend can never complete its close.
5. The Windows driver waits for the backend with a busy loop, which is why the guest is
   wedged rather than merely lacking network. (That part is a Xen PV driver defect and I am
   reporting it separately; it is what turns this into an unusable qube.)

### Ruled out by measurement/source
- Multi-queue: mirage publishes no `multi-queue-max-queues`, so xenvif correctly falls back to
  `NumQueues = 1` and the flat `tx-ring-ref`/`rx-ring-ref`/`event-channel` layout mirage reads.
  Forcing `FrontendMaxQueues = 1` in the guest changes nothing (tested).
- Feature negotiation: every backend key mirage omits is optional for xenvif with a safe
  default; `read_feature` defaults missing frontend keys to `false`.
- Missing `ip` key: both vifs have one (`10.137.0.64`).
- QWT build, feature set (`ADDLOCAL` subset vs all), vCPU count, memory, install-time
  netvm presence: all eliminated by A/B measurement.

### What would help
1. Handle the HVM `vif_ioemu` device so its handshake completes (primary).
2. Stop waiting when the frontend reports `Closing`/`Closed`, and tear the backend down, so a
   frontend that gives up can at least finish closing.

Happy to run further diagnostics on the affected setup, add debug logging to the unikernel, or
test a patch — the reproduction is reliable and takes about three minutes.
