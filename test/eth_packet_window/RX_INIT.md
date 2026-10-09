# GEM ring initialization regression

Run from a checkout containing the bundled `emacps_v3_8` BSP:

```sh
python3 test/eth_packet_window/run_rx_init.py
python3 test/eth_packet_window/run_rx_init.py --legacy
```

`--cc` selects the host C compiler. An optional case name runs one group:
`success`, `fence`, `rx-create`, `rx-clone`, `tx-create`, `tx-clone`, `alloc`,
`prepare`, `commit`, or `rearm`. The runner removes its generated C/binary directory.

This supplements [RX_BD.md](RX_BD.md): that fixture exercises live receive/refill;
this one executes the actual `init_ethernet_buffers`, `ethernet_prepare_rx_bd`
and `ethernet_clear_host_state` bodies. It uses actual bundled BSP Create, Clone,
Alloc, UnAlloc, ToHw and wrap helpers, descriptor macros and ring layout. RX/TX
counts come from the firmware header (64 RX / 4 TX at the reviewed commit).

The observer checks that Stop and successful fence precede clearing host state
and ring creation; cloned RX descriptors have NEW set; cloned TX descriptors
have USED set; and the final descriptors retain their wrap bits. Every NEW clear
must follow successful bulk ToHw, the barrier, all 64 reservations and correct
slot addresses. Rearm must succeed before Start. `success` covers both the first
session and another initialization after a prior successful session.

Failure cases cover:

- Fence rejection: ring metadata, descriptor bytes and slot mappings/counts
  remain unchanged; DMA stays stopped.
- RX/TX Create or Clone rejection and Alloc exhaustion: no ownership publication
  or Start; a subsequent initialization succeeds.
- Prepare failure at descriptor 0, 7 or 63: the allocated group is unwound,
  reservations and slot mappings are cleared, and all RX descriptors remain
  software-owned. A subsequent initialization succeeds.
- Rejected bulk ToHw: no NEW clear occurs; the allocated group/reservations are
  unwound, and retry succeeds.
- Rearm failure after descriptor publication: DMA stays stopped and reservations
  remain. A retry whose fence fails cannot clear those descriptors; a later
  successful fence permits rebuilding and Start.

Wrappers inject invalid alignment, running-ring clone rejection, excessive
allocation and out-of-sequence ToHw into the actual BSP routines. Prepare uses
an injected high-watermark condition to exercise its actual rejection path.
Fence/rearm and Stop/Start are explicit boundary stubs, so their internal register,
cache, drain and timing behavior is not tested here. The existing live/session
fixtures exercise the fence/rearm implementations separately. Both modes test
init's response to a rejected boundary call; this does not claim the current
legacy fence can actually time out. TX completion/order processing is not tested.

Host adaptations are confined to pointer-sized descriptor indexing, backing
arrays instead of fixed physical ring addresses, synthetic 32-bit payload
addresses, an explicit `(void)` init prototype and a void-use of the BSP Create
routine's otherwise unused `BdPhyAddr` local. The latter preserves its calculation
and all branches without disabling compiler warnings. Target 32-bit descriptor
macros/alignment are selected explicitly. MMIO/cache and TX-order-flush effects
are stubbed; actual host-state clearing remains in the extracted firmware body.
The runner reuses only the extraction helpers from `run_rx_bd.py` and suppresses
Python bytecode output, not compiler diagnostics.

At production source `9a790af25b53d798d27e6f587f896b8c46463855`, ten groups pass
in each mode with Clang C99, `-Wall -Wextra -Werror -pedantic`, ASan and UBSan.
Four temporary source mutations each fail a runtime assertion: omit the RX NEW
template, omit the pre-handoff barrier, ignore a failed fence, or Start before
successful rearm. They are not included in the branch. No production firmware or
RTL change is made; this is control-flow/ownership coverage, not hardware boot
validation or a throughput measurement.
