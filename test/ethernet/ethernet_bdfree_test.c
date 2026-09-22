/*
 * Host unit tests for RX BD-ring capacity accounting in ethernet.c.
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Build/run: make -C test/ethernet test
 *
 * These cover DETECTION only. There is deliberately no watchdog or restart
 * here: recovery is a separate policy, and a full DMA restart also destroys
 * in-flight TX, so it must not be entangled with detecting the fault.
 *
 * T0 CONTROL   receive/repost cycles with no injected failure; free-BD count
 *              sampled only at matched quiescent points must return to
 *              baseline. Without this control a stranding assertion proves
 *              nothing, because it cannot tell a leak from normal churn.
 * T1 STRANDING inject K BdRingFree failures; assert exactly K BDs stranded,
 *              the diagnostic counter incremented exactly once per failed
 *              CALL, reservation/slot bookkeeping still self-consistent, no
 *              stale mapping and no double release.
 */
#include <stdio.h>
#include <string.h>
#include "xemacps.h"
#include "ethernet.h"
#include "zz_regs.h"

/* Not exported in ethernet.h; declared here rather than widening the
 * firmware header for a test. EmacPsInstance is static in ethernet.c, so the
 * ring is reached through a test-only accessor instead. */
extern XEmacPs_BdRing *ethernet_mock_rx_ring(void);
extern void ethernet_mock_recv_handler(void);
extern int  ethernet_get_backlog(void);
extern int  ethernet_receive_frame(u16 acked_serial);
extern int  init_ethernet_buffers(void);
extern void ethernet_alloc_rx_frames(void);
extern u16  ethernet_mock_occupied_slots(void);
extern u32  ethernet_get_rx_diag_word(void);

static int failures = 0;
static int checks = 0;

static void check_eq(const char *name, long got, long want)
{
    checks++;
    if (got != want) {
        failures++;
        printf("MISMATCH %-34s got=%ld want=%ld\n", name, got, want);
    }
}

/* Capacity at a quiescent point. Deliberately NOT the free-BD count: after
 * init every BD is committed to hardware, so free is 0 both before and after
 * and the comparison would pass vacuously. What matters is how many BDs are
 * still in circulation at all -- a BD stranded outside the free list is lost
 * capacity even though free_bds legitimately rises and falls during normal
 * receive and repost. */
static u32 quiescent_capacity(void)
{
    return mock_rx_capacity();
}

/* One receive/repost cycle: hand the BDs to hardware, take them back as if
 * frames landed, and release them. */
/* One full receive/repost cycle through the firmware's own code paths:
 * frames land via the recv handler (which is where the BdRingFree under test
 * lives), the host acks them, and the BDs are reposted. Acking matters -- an
 * unacked backlog reaches the high watermark and latches backpressure, after
 * which no BD is reposted and later cycles would silently do nothing. */
static void rx_cycle(u32 n)
{
    (void)n;
    ethernet_mock_recv_handler();
    while (ethernet_get_backlog() > 0)
        (void)ethernet_receive_frame(1);   /* legacy bare advance */
    ethernet_alloc_rx_frames();
}

int main(void)
{
    mock_ring_reset();

    if (init_ethernet_buffers() != 0) {
        printf("RESULT FAIL checks=0 errors=1 (init_ethernet_buffers)\n");
        return 1;
    }

    /* ---- T0: control, no injected failure ------------------------- */
    u32 baseline = quiescent_capacity();
    check_eq("T0_counter_starts_zero", ethernet_get_rx_bdfree_failures(), 0);

    for (int i = 0; i < 8; i++)
        rx_cycle(4);

    check_eq("T0_capacity_returns_to_baseline", quiescent_capacity(), baseline);
    check_eq("T0_no_stranded_bds",              mock_rx_stranded_count(), 0);
    check_eq("T0_no_double_release",            mock_rx_double_release(), 0);
    check_eq("T0_counter_still_zero",           ethernet_get_rx_bdfree_failures(), 0);
    check_eq("T0_bdfree_was_actually_called",   mock_bdfree_calls > 0, 1);

    /* ---- T1: injected BdRingFree failure ------------------------- */
    /* The receive path frees every BD it reclaimed in ONE call, so a single
     * failure strands all of them at once. That makes this the sharpest form
     * of the exact-once property: N BDs lost through one failed call must
     * increment the counter by 1, not by N. */
    mock_bdfree_failed_calls = 0;
    u32 before_cap = quiescent_capacity();
    u32 in_flight  = mock_rx_inflight();
    check_eq("T1_precondition_bds_in_flight", in_flight > 0, 1);

    mock_bdfree_fail_remaining = 1;
    rx_cycle(0);

    check_eq("T1_one_failed_call",        mock_bdfree_failed_calls, 1);
    check_eq("T1_counter_exact_once",     ethernet_get_rx_bdfree_failures(), 1);
    check_eq("T1_not_counted_per_bd",     ethernet_get_rx_bdfree_failures() == in_flight, 0);
    check_eq("T1_stranded_bds_exact",     mock_rx_stranded_count(), in_flight);
    check_eq("T1_capacity_lost_exactly",  (long)before_cap - (long)quiescent_capacity(),
                                          (long)in_flight);
    check_eq("T1_no_double_release",      mock_rx_double_release(), 0);

    /* Reservation/slot consistency: reserved must still equal the number of
     * occupied slot-table entries. This is what separates ring stranding
     * from counter drift -- capacity is gone while the reservation
     * bookkeeping remains perfectly correct, so a test that only checked
     * counters would see nothing wrong. */
    u16 status = ethernet_get_rx_status();
    u16 reserved = (u16)((status >> 8) & 0x7f);
    check_eq("T1_reserved_matches_slots", reserved, ethernet_mock_occupied_slots());

    /* The previous revision asserted the counter was "stable under further
     * healthy traffic" here. That was misleading: once the ring is stranded
     * there is no traffic at all, so the assertion re-read the same value
     * and proved nothing. Assert the real consequences instead.
     *
     * (a) The strand is PERMANENT without a reset. */
    mock_bdfree_fail_remaining = 0;
    u32 calls_before = (u32)mock_bdfree_calls;
    for (int i = 0; i < 4; i++)
        rx_cycle(0);
    check_eq("T1_ring_does_not_self_recover", quiescent_capacity(), 0);
    /* (b) and those cycles really were no-ops -- stated explicitly so this
     * can never be mistaken for a healthy-traffic test again. */
    check_eq("T1_no_further_frees_attempted", (u32)mock_bdfree_calls, calls_before);
    check_eq("T1_counter_did_not_climb",      ethernet_get_rx_bdfree_failures(), 1);

    /* (c) The PostHead cascade itself: the real ring refuses a release that
     * does not start at PostHead, or that covers more BDs than are posted.
     * That refusal is WHY one failed free cascades -- the stranded set stays
     * at the head and blocks every later release. Asserted behaviourally
     * against the contract, not by reading the field. */
    XEmacPs_BdRing *rx = ethernet_mock_rx_ring();
    XEmacPs_Bd *head = mock_rx_post_head();
    u32 posted = mock_rx_stranded_count();
    check_eq("T1_cascade_precondition_posted", posted > 1, 1);
    check_eq("T1_free_rejects_overlong",
             XEmacPs_BdRingFree(rx, posted + 1, head) == XST_SUCCESS, 0);
    check_eq("T1_free_rejects_wrong_head",
             XEmacPs_BdRingFree(rx, 1, head + 1) == XST_SUCCESS, 0);
    /* a refused release must not have mutated the ring */
    check_eq("T1_refusals_left_ring_intact", mock_rx_stranded_count(), posted);

    /* ---- T2: the REG_ZZ_ETH_DIAG read contract -------------------- */
    /* main.c's read dispatch is not compiled into this suite, which is
     * exactly how the original 0x62 blocker got through: a case label for an
     * odd-word register can never match, because the dispatch switches on
     * (zaddr & 0xffffffc). Cover the two properties of that contract which
     * ARE checkable from here. */
    check_eq("T2_register_survives_dispatch_mask",
             (REG_ZZ_ETH_DIAG & 0xffffffc) == REG_ZZ_ETH_DIAG, 1);

    u32 word = ethernet_get_rx_diag_word();
    check_eq("T2_word_nonzero_after_failure", word != 0, 1);
    check_eq("T2_count_in_high_half",  word >> 16, ethernet_get_rx_bdfree_failures());
    check_eq("T2_low_half_clear",      word & 0xffff, 0);

    if (failures == 0)
        printf("RESULT PASS checks=%d\n", checks);
    else
        printf("RESULT FAIL checks=%d errors=%d\n", checks, failures);
    return failures ? 1 : 0;
}
