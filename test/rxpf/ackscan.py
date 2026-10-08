#!/usr/bin/env python3
"""ackscan.py <pcap> <amiga-ip>: how the Amiga acknowledges an inbound iperf flow.

Hand-rolled pcap walk (no dpkt/scapy here).  Sender-side capture: data from
the peer to the Amiga, ACKs back.  Reports, for the bulk flow:
  - ACK count, inter-ACK gap percentiles, bytes newly acked per ACK
  - sender-side RTT samples: time from a data segment leaving to the ACK that
    first covers its last byte (Karn: skip retransmitted ranges)
  - advertised window over the run, retransmitted data segments
"""
import struct, sys, statistics

def packets(path):
    with open(path, 'rb') as f:
        gh = f.read(24)
        magic = struct.unpack('<I', gh[:4])[0]
        en = '<' if magic in (0xa1b2c3d4, 0xa1b23c4d) else '>'
        nano = magic in (0xa1b23c4d, 0x4d3cb2a1)
        linktype = struct.unpack(en + 'I', gh[20:24])[0]
        while True:
            h = f.read(16)
            if len(h) < 16:
                return
            ts, tus, incl, orig = struct.unpack(en + 'IIII', h)
            data = f.read(incl)
            t = ts + tus / (1e9 if nano else 1e6)
            off = 14 if linktype == 1 else 16 if linktype == 113 else 0
            if linktype == 1:
                et = struct.unpack('>H', data[12:14])[0]
                if et == 0x8100:
                    off = 18
            ip = data[off:]
            if len(ip) < 20 or ip[0] >> 4 != 4 or ip[9] != 6:
                continue
            ihl = (ip[0] & 15) * 4
            tot = struct.unpack('>H', ip[2:4])[0]
            src = '.'.join(map(str, ip[12:16])); dst = '.'.join(map(str, ip[16:20]))
            tcp = ip[ihl:]
            sp, dp, seq, ack, offf, flags, win = struct.unpack('>HHIIBBH', tcp[:16])
            thl = (offf >> 4) * 4
            plen = tot - ihl - thl
            # window scale from SYN options is not needed for relative trends
            yield t, src, dst, sp, dp, seq, ack, flags, win, plen

def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p / 100 * len(v)))] if v else 0

def main():
    path, amiga = sys.argv[1], sys.argv[2]
    pk = list(packets(path))
    # the bulk flow: peer -> amiga with the most payload
    flows = {}
    for p in pk:
        if p[2] == amiga and p[9] > 0:
            flows[(p[1], p[3], p[4])] = flows.get((p[1], p[3], p[4]), 0) + p[9]
    (peer, sport, dport), nbytes = max(flows.items(), key=lambda kv: kv[1])
    data = [p for p in pk if p[1] == peer and p[2] == amiga and p[3] == sport and p[4] == dport and p[9] > 0]
    acks = [p for p in pk if p[1] == amiga and p[2] == peer and p[3] == dport and p[4] == sport]
    t0 = data[0][0]; t1 = data[-1][0]
    print(f"flow {peer}:{sport} -> {amiga}:{dport}  {nbytes} payload bytes over {t1 - t0:.2f} s"
          f" = {nbytes * 8 / max(t1 - t0, 1e-9) / 1e6:.2f} Mbit/s")
    # data segments, retransmissions
    sent = {}; retx = 0; seen_hi = None
    for t, s, d, sp, dp, seq, ack, fl, win, plen in data:
        end = (seq + plen) & 0xffffffff
        if seen_hi is not None and ((end - seen_hi) & 0xffffffff) > 0x7fffffff:
            retx += 1; sent[end] = None   # Karn: ambiguous
        else:
            if end not in sent:
                sent[end] = t
            seen_hi = end if seen_hi is None or ((end - seen_hi) & 0xffffffff) < 0x7fffffff else seen_hi
    print(f"data segments {len(data)} (capture frames, TSO may merge), retransmitted-looking {retx}")
    # ACK behaviour
    gaps = []; newly = []; wins = []; last_ack = None; last_t = None; dup = 0
    for t, s, d, sp, dp, seq, ack, fl, win, plen in acks:
        if not (fl & 0x10):
            continue
        wins.append(win)
        if last_ack is not None:
            adv = (ack - last_ack) & 0xffffffff
            if adv == 0 or adv > 0x7fffffff:
                dup += 1
            else:
                newly.append(adv)
                gaps.append((t - last_t) * 1000)
        last_ack, last_t = ack, t
    print(f"ACKs {len(acks)}  advancing {len(newly)}  duplicate/non-advancing {dup}")
    for name, v, unit in (("inter-ACK gap", gaps, "ms"), ("bytes acked per ACK", newly, "B")):
        print(f"{name:20s} p10 {pct(v,10):.1f}  p50 {pct(v,50):.1f}  p90 {pct(v,90):.1f}  p99 {pct(v,99):.1f}  max {max(v) if v else 0:.1f} {unit}")
    big = [g for g in gaps if g > 150]
    print(f"inter-ACK gaps > 150 ms: {len(big)}  (sum {sum(big)/1000:.2f} s of {t1 - t0:.2f} s)")
    # RTT samples: data end-seq -> first ACK covering it
    ends = sorted((e, t) for e, t in sent.items() if t is not None)
    rtts = []; i = 0
    for t, s, d, sp, dp, seq, ack, fl, win, plen in acks:
        while i < len(ends) and ((ack - ends[i][0]) & 0xffffffff) < 0x7fffffff:
            rtts.append((t - ends[i][1]) * 1000); i += 1
    print(f"RTT samples {len(rtts)}: p10 {pct(rtts,10):.1f}  p50 {pct(rtts,50):.1f}  p90 {pct(rtts,90):.1f}  max {max(rtts) if rtts else 0:.1f} ms")
    print(f"advertised window (raw, unscaled) min {min(wins)} p50 {pct(wins,50)} max {max(wins)}")

main()
