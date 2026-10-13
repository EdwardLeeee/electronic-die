#!/usr/bin/env python3
"""Measure the statistical quality of the 64-bit cellular-automaton RNG (plan M2).

Standard library only.  Run from the repository root:

    python3 -I model/rng_analysis.py --md docs/rng_analysis.md --json build/rng_analysis.json
    python3 -I model/rng_analysis.py --md docs/rng_analysis.md --json build/rng_analysis.json --quick
    python3 -I model/rng_analysis.py --md docs/rng_analysis.md --json build/rng_analysis.json --render-only

The script writes the JSON first, reads it back from disk and renders the
markdown from the parsed data, so every number in docs/rng_analysis.md comes
from build/rng_analysis.json and the two cannot drift.  --quick divides the
sample sizes by about 100 for a smoke run; --render-only regenerates the
markdown from an existing JSON without recomputing anything.
"""
from __future__ import annotations

import argparse
import json
import math
import operator
import os
import random
import sys
import time
from datetime import datetime, timezone

# `python3 -I` does not put the script's directory on sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ca_rng import LUT, MASK, WIDTH, ca_step, ca_step_fast, die_value, fmt  # noqa: E402

SEEDS = [("course", 122059), ("dense", 0xDEADBEEFCAFEF00D)]
SIZES = {
    "full": dict(draws=1_000_000, period_cap=10_000_000, survey_seeds=2000, survey_cap=10_000, census_max_period=5),
    "quick": dict(draws=10_000, period_cap=100_000, survey_seeds=20, survey_cap=100, census_max_period=3),
}
SURVEY_RNG_SEED = 20261014  # random.Random seed for the survey seeds (reproducible)
MIN_TAIL_DRAWS = 1000       # analyse the pre-cycle tail separately only if it is at least this long
FACES = 6
BASELINE_FMAX_MHZ = 10.96   # electronic-die/synth/quartus/electronic_die.tan.summary (Quartus II 9.0 SP2, EP2S15F484C3)

COMMANDS = {
    "full": "python3 -I model/rng_analysis.py --md docs/rng_analysis.md --json build/rng_analysis.json",
    "quick": "python3 -I model/rng_analysis.py --md build/rng_analysis_quick.md --json build/rng_analysis_quick.json --quick",
    "render_only": "python3 -I model/rng_analysis.py --md docs/rng_analysis.md --json build/rng_analysis.json --render-only",
    "selftest": "python3 -I model/ca_rng.py selftest",
    "plot": "uv run --with matplotlib python3 model/plot_rng.py build/rng_analysis.json docs/img/die_histogram.png",
}

T0 = time.perf_counter()


def log(msg: str) -> None:
    print(f"[{time.perf_counter() - T0:7.1f}s] {msg}", file=sys.stderr, flush=True)


def rotl(x: int, n: int) -> int:
    n %= WIDTH
    return ((x << n) | (x >> (WIDTH - n))) & MASK


# ----------------------------------------------------------------------------
# chi-square upper tail in pure Python
# ----------------------------------------------------------------------------
def chi2_sf(x: float, dof: int) -> float:
    """P[chi2(dof) > x] = Q(a, y) with a = dof/2, y = x/2, where Q is the
    regularised upper incomplete gamma function Gamma(a, y) / Gamma(a).

    Starting values:   Q(1/2, y) = erfc(sqrt(y))        (dof odd)
                       Q(1, y)   = exp(-y)              (dof even)
    Recurrence:        Q(a + 1, y) = Q(a, y) + y^a e^-y / Gamma(a + 1)
    Every term is positive, so the sum is numerically stable; the term is
    evaluated in log space to avoid overflow of y^a for large statistics.
    Below about 1e-308 the result underflows to 0.0 (reported as < 1e-300).
    """
    if dof < 1:
        raise ValueError("dof must be >= 1")
    y = x / 2.0
    if y <= 0.0:
        return 1.0
    if dof % 2:
        a, q = 0.5, math.erfc(math.sqrt(y))
    else:
        a, q = 1.0, math.exp(-y)
    for _ in range((dof - 1) // 2 if dof % 2 else (dof - 2) // 2):
        q += math.exp(a * math.log(y) - y - math.lgamma(a + 1.0))
        a += 1.0
    return min(1.0, q)


def goodness_of_fit(counts: list[int]) -> dict:
    """Chi-square of observed counts against equal expected counts."""
    n = sum(counts)
    k = len(counts)
    e = n / k
    chi2 = sum((c - e) ** 2 / e for c in counts) if n else 0.0
    return {"counts": counts, "n": n, "expected": e, "chi2": chi2, "dof": k - 1, "p_value": chi2_sf(chi2, k - 1)}


def contingency(matrix: list[list[int]]) -> dict:
    """Pearson chi-square test of independence on a contingency table."""
    rows = [sum(r) for r in matrix]
    cols = [sum(matrix[i][j] for i in range(len(matrix))) for j in range(len(matrix[0]))]
    total = sum(rows)
    chi2, min_e = 0.0, float("inf")
    for i, r in enumerate(rows):
        for j, c in enumerate(cols):
            e = r * c / total
            min_e = min(min_e, e)
            if e:
                chi2 += (matrix[i][j] - e) ** 2 / e
    dof = (len(rows) - 1) * (len(cols) - 1)
    return {"matrix": matrix, "row_sums": rows, "col_sums": cols, "pairs": total, "min_expected_cell": min_e,
            "chi2": chi2, "dof": dof, "p_value": chi2_sf(chi2, dof)}


# ----------------------------------------------------------------------------
# Brent's cycle finding
# ----------------------------------------------------------------------------
def certified_distinct_steps(cap: int) -> int:
    """Largest 2^j such that Brent with `cap` hare steps finds every cycle with
    mu + lambda <= 2^j.  The tortoise is parked at positions 2^k - 1; a cycle
    (mu, lambda) with mu <= 2^k - 1 and lambda <= 2^k is found when the hare
    reaches position 2^k - 1 + lambda <= 2^(k+1) - 1.  So if no cycle was found
    within `cap` steps, the states state[0..2^j] are pairwise distinct for the
    largest j with 2^(j+1) - 1 <= cap."""
    return 1 << ((cap + 1).bit_length() - 2)


def brent(seed: int, cap: int) -> dict:
    """Brent's algorithm on state -> ca_step_fast(state), at most `cap` hare
    steps in the search phase.  Returns mu (tail length) and lam (cycle
    length) if a cycle was found, otherwise the certified repeat-free prefix."""
    f = ca_step_fast
    x0 = seed & MASK
    power = lam = 1
    tortoise = x0
    hare = f(x0)
    steps = 1
    while tortoise != hare:
        if power == lam:  # park the tortoise at the next power of two
            tortoise = hare
            power <<= 1
            lam = 0
        if steps >= cap:
            return {"seed_hex": f"{x0:#018x}", "cap": cap, "found": False, "hare_steps": steps,
                    "certified_distinct_steps": certified_distinct_steps(cap)}
        hare = f(hare)
        steps += 1
        lam += 1
    # second phase: position of the first repeated state
    tortoise = hare = x0
    for _ in range(lam):
        hare = f(hare)
    mu = 0
    while tortoise != hare:
        tortoise = f(tortoise)
        hare = f(hare)
        mu += 1
    return {"seed_hex": f"{x0:#018x}", "cap": cap, "found": True, "mu": mu, "lam": lam,
            "hare_steps": steps, "phase2_steps": lam + 2 * mu, "cycle_entry_hex": f"{tortoise:#018x}"}


def cycle_profile(entry: int, lam: int) -> dict:
    """Describe the states of a cycle: die values, faces used, shift structure."""
    states = [entry]
    for _ in range(lam - 1):
        nxt = ca_step_fast(states[-1])
        assert ca_step(states[-1]) == nxt  # every step of the cycle re-checked with the bit-by-bit model
        states.append(nxt)
    assert ca_step_fast(states[-1]) == entry and ca_step(states[-1]) == entry
    dies = [die_value(s) for s in states]
    counts = [dies.count(k) for k in range(1, FACES + 1)]
    shift = None
    for k in range(1, lam):
        for n in range(WIDTH):
            if states[k] == rotl(states[0], n):
                direction = f"left by {n}" if n <= WIDTH // 2 else f"right by {WIDTH - n}"
                shift = {"steps": k, "rotl_cells": n,
                         "description": f"state[j+{k}] = state[j] rotated {direction} cell(s)"}
                break
        if shift:
            break
    pops = [s.bit_count() for s in states]
    return {"length": lam, "entry_hex": f"{entry:#018x}", "die_sequence": "".join(map(str, dies)),
            "face_counts": counts, "faces_absent": [k + 1 for k, c in enumerate(counts) if c == 0],
            "shift": shift, "popcount_min": min(pops), "popcount_max": max(pops), "popcount_mean": sum(pops) / lam}


# ----------------------------------------------------------------------------
# one pass over N consecutive states: faces, transitions, autocorrelation, bits
# ----------------------------------------------------------------------------
def main_pass(seed: int, n: int) -> dict:
    """Draw j (j = 0..n-1) is die(state[j]); see docs/verification.md section 2:
    with en held at 1 the output after edge m >= 2 is die(state[m-2]) (edge 1
    only loads the seed), so n + 1 clocks show the n states state[0..n-1]
    exactly once, in order."""
    f = ca_step_fast
    s = seed & MASK
    counts = [0] * FACES
    trans = [[0] * FACES for _ in range(FACES)]
    lanes = [[0] * 256 for _ in range(8)]  # byte histograms -> per-cell one counts
    l0, l1, l2, l3, l4, l5, l6, l7 = lanes
    draws: list[int] = []
    append = draws.append
    seen: set[int] = set()
    add = seen.add
    ones_total = 0
    prev = s % 6
    for _ in range(n):
        d = s % 6
        counts[d] += 1
        trans[prev][d] += 1
        prev = d
        append(d)
        b = s.to_bytes(8, "little")
        l0[b[0]] += 1; l1[b[1]] += 1; l2[b[2]] += 1; l3[b[3]] += 1  # noqa: E702
        l4[b[4]] += 1; l5[b[5]] += 1; l6[b[6]] += 1; l7[b[7]] += 1  # noqa: E702
        ones_total += s.bit_count()
        add(s)
        s = f(s)
    trans[draws[0]][draws[0]] -= 1  # the first draw has no predecessor (prev was initialised to it)
    distinct = len(seen)
    del seen

    # 4. per-cell bit balance (needed early: cell 0 is the face parity)
    per_cell_ones = []
    for lane in range(8):
        hist = lanes[lane]
        for bitpos in range(8):
            per_cell_ones.append(sum(hist[v] for v in range(256) if (v >> bitpos) & 1))
    per_cell = [c / n for c in per_cell_ones]
    cmean = sum(per_cell) / WIDTH
    cstd = math.sqrt(sum((p - cmean) ** 2 for p in per_cell) / WIDTH)
    sd_iid = math.sqrt(0.25 / n)
    order = sorted(range(WIDTH), key=lambda i: -abs(per_cell[i] - 0.5))
    bit_balance = {
        "steps": n, "per_cell_ones_fraction": per_cell,
        "min": min(per_cell), "argmin": per_cell.index(min(per_cell)),
        "max": max(per_cell), "argmax": per_cell.index(max(per_cell)),
        "mean": cmean, "std": cstd, "sd_iid": sd_iid,
        "worst_cells": [{"cell": i, "ones_fraction": per_cell[i], "z": (per_cell[i] - 0.5) / sd_iid} for i in order[:5]],
        "cells_beyond_3sd": sum(abs(p - 0.5) > 3 * sd_iid for p in per_cell),
        "overall_ones_fraction": ones_total / (WIDTH * n),
    }

    # 1. uniformity: chi-square with 5 degrees of freedom against n/6 per face,
    #    plus the parity decomposition.  die(x) = (x mod 6) + 1 is even exactly
    #    when x is odd, i.e. when cell 0 is 1, so P(even face) is the density of
    #    ones in cell 0.
    gof = goodness_of_fit(counts)
    n_even_face = counts[1] + counts[3] + counts[5]
    uniformity = {
        "draws": n, "counts": counts, "expected_per_face": gof["expected"],
        "relative_deviation": [(c - gof["expected"]) / gof["expected"] for c in counts],
        "chi2": gof["chi2"], "dof": gof["dof"], "p_value": gof["p_value"],
        "parity": {
            "even_face_count": n_even_face, "even_face_fraction": n_even_face / n,
            "cell0_ones_count": per_cell_ones[0], "consistent": n_even_face == per_cell_ones[0],
            **{k: v for k, v in goodness_of_fit([n - n_even_face, n_even_face]).items() if k in ("chi2", "dof", "p_value")},
        },
        "odd_faces": goodness_of_fit([counts[0], counts[2], counts[4]]),
        "even_faces": goodness_of_fit([counts[1], counts[3], counts[5]]),
        "mod3": goodness_of_fit([counts[0] + counts[3], counts[1] + counts[4], counts[2] + counts[5]]),
    }

    # 2. independence of consecutive draws: contingency chi-square on the 6x6
    #    transition matrix of overlapping pairs (Anderson-Goodman test of a
    #    zero-order against a first-order Markov chain), (6-1)^2 = 25 dof;
    #    the same test on the face parity (2x2, 1 dof) and on x mod 3 (3x3, 4 dof).
    independence = contingency(trans)
    par = [[0, 0], [0, 0]]   # index 0 = odd face (d even), 1 = even face (d odd)
    m3 = [[0] * 3 for _ in range(3)]
    for i in range(FACES):
        for j in range(FACES):
            par[i % 2][j % 2] += trans[i][j]
            m3[i % 3][j % 3] += trans[i][j]
    parity_t = contingency(par)
    r_odd, r_even = parity_t["row_sums"]
    a, b_, c, d_ = par[0][0], par[0][1], par[1][0], par[1][1]
    denom = math.sqrt(r_odd * r_even * parity_t["col_sums"][0] * parity_t["col_sums"][1]) or 1.0
    parity_t.update({
        "p_even_given_even": d_ / r_even if r_even else None,
        "p_even_given_odd": b_ / r_odd if r_odd else None,
        "phi": (a * d_ - b_ * c) / denom,
    })
    independence["parity"] = parity_t
    independence["mod3"] = contingency(m3)

    # 3. lag-1..8 autocorrelation of the die-value sequence:
    #    r_L = sum_{j<n-L} (x_j - m)(x_{j+L} - m) / sum_j (x_j - m)^2, m = mean
    mean = sum(draws) / n + 1  # die values are draws + 1; centring removes the offset
    xc = [d + 1 - mean for d in draws]
    var_sum = sum(map(operator.mul, xc, xc))
    lags = []
    for lag in range(1, 9):
        num = sum(map(operator.mul, xc, xc[lag:]))
        lags.append({"lag": lag, "r": num / var_sum if var_sum else 0.0})
    #    The same for the parity sequence (1 = even face), which carries the
    #    dependence that the rule's self-bias creates.
    pmean = n_even_face / n
    pc = [(d & 1) - pmean for d in draws]
    pvar = sum(map(operator.mul, pc, pc))
    parity_lags = []
    for lag in range(1, 9):
        num = sum(map(operator.mul, pc, pc[lag:]))
        parity_lags.append({"lag": lag, "r": num / pvar if pvar else 0.0})
    del xc, pc, draws
    se = 1 / math.sqrt(n)
    autocorrelation = {
        "n": n, "mean": mean, "variance": var_sum / n, "ideal_mean": 3.5, "ideal_variance": 35 / 12,
        "lags": lags, "se_iid": se, "band95": 1.96 * se,
        "max_abs_r": max(abs(x["r"]) for x in lags),
        "parity_lags": parity_lags,
    }

    return {
        "draws": n, "uniformity": uniformity, "independence": independence, "autocorrelation": autocorrelation,
        "bit_balance": bit_balance,
        "distinct_prefix": {"states": n, "distinct": distinct, "all_distinct": distinct == n},
    }


# ----------------------------------------------------------------------------
# short-cycle survey and exhaustive census
# ----------------------------------------------------------------------------
def summarise_group(results: list[dict]) -> dict:
    found = [r for r in results if r["found"]]
    lam_hist: dict[int, int] = {}
    fixed_points: dict[str, int] = {}
    for r in found:
        lam_hist[r["lam"]] = lam_hist.get(r["lam"], 0) + 1
        if r["lam"] == 1:
            fixed_points[r["cycle_entry_hex"]] = fixed_points.get(r["cycle_entry_hex"], 0) + 1
    mus = [r["mu"] for r in found]
    return {
        "seeds": len(results), "found": len(found), "not_found": len(results) - len(found),
        "cycle_length_histogram": {str(k): v for k, v in sorted(lam_hist.items())},
        "fixed_points_reached": fixed_points,
        "mu_min": min(mus) if mus else None, "mu_max": max(mus) if mus else None,
        "mu_mean": sum(mus) / len(mus) if mus else None,
        "found_cycles": [{"seed_hex": r["seed_hex"], "mu": r["mu"], "lam": r["lam"], "cycle_entry_hex": r["cycle_entry_hex"]}
                         for r in found][:64],
    }


def survey(n_random: int, cap: int) -> dict:
    rnd = random.Random(SURVEY_RNG_SEED)
    seeds = [rnd.getrandbits(WIDTH) for _ in range(n_random)]
    random_results = []
    for k, s in enumerate(seeds):
        random_results.append(brent(s, cap))
        if (k + 1) % max(1, n_random // 4) == 0:
            log(f"  survey: {k + 1}/{n_random} random seeds")
    single_results = [brent(1 << i, cap) for i in range(WIDTH)]
    single_sig = {(r["found"], r.get("mu"), r.get("lam")) for r in single_results}
    return {
        "cap": cap, "certified_distinct_steps": certified_distinct_steps(cap),
        "random_generator_seed": SURVEY_RNG_SEED,
        "random": summarise_group(random_results),
        "single_bit": {**summarise_group(single_results),
                       "all_identical": len(single_sig) == 1,
                       "note": "the 64 single-bit seeds are one rotation class of the (rotation-invariant) CA"},
    }


def census(p: int, list_limit: int = 64) -> dict:
    """Exact number of states x with f^p(x) = x, by a transfer-matrix count of
    cyclic 64-bit strings.  Cell i of f^p(x) depends on cells i-p..i+2p, a
    window of w = 3p+1 cells; a state is a solution iff every window satisfies
    cell_i == f^p(window)_i.  Closed walks of length 64 through the graph of
    overlapping (w-1)-cell windows are counted by dynamic programming."""
    w = 3 * p + 1

    def ok(bits: int) -> bool:
        seg = [(bits >> j) & 1 for j in range(w)]  # seg[j] = cell i-p+j
        centre = seg[p]
        for _ in range(p):
            seg = [LUT[(seg[j] << 3) | (seg[j - 1] << 2) | (seg[j + 2] << 1) | seg[j + 1]] for j in range(1, len(seg) - 2)]
        return seg[0] == centre

    top = w - 1
    nstates = 1 << top
    succ = [[(s | (b << top)) >> 1 for b in (0, 1) if ok(s | (b << top))] for s in range(nstates)]
    total = 0
    sols: list[int] = []
    for s0 in range(nstates):
        vec = {s0: 1}
        for _ in range(WIDTH):
            new: dict[int, int] = {}
            for s, c in vec.items():
                for t in succ[s]:
                    new[t] = new.get(t, 0) + c
            vec = new
            if not vec:
                break
        c0 = vec.get(s0, 0)
        total += c0
        if c0 and len(sols) < list_limit:  # enumerate the closed walks from s0
            stack = [(s0, 0, 0)]
            while stack:
                s, k, acc = stack.pop()
                if k == WIDTH:
                    if s == s0:
                        sols.append((s0 | (acc << top)) & MASK)
                    continue
                for t in succ[s]:
                    stack.append((t, k + 1, acc | ((t >> (top - 1)) << k)))
    states = []
    for x in sorted(set(sols)):
        y = x
        for _ in range(p):
            y = ca_step_fast(y)
        assert y == x and ca_step(x) == ca_step_fast(x)
        per, y = 1, ca_step_fast(x)
        while y != x:
            y = ca_step_fast(y)
            per += 1
        states.append({"state_hex": f"{x:#018x}", "min_period": per, "die": die_value(x)})
    return {"period": p, "window_cells": w, "overlap_states": nstates, "count": total,
            "listed": len(states), "states": states}


def fixed_point_checks() -> dict:
    out = {"lut_0000": LUT[0], "lut_1111": LUT[15], "lut_0101": LUT[5], "lut_1010": LUT[10], "states": []}
    alt = int("01" * (WIDTH // 2), 2)  # 0x5555...: cell i is 1 for even i
    for name, x in (("all-zero", 0), ("all-one", MASK), ("alternating 0101", alt), ("alternating 1010", MASK ^ alt)):
        out["states"].append({"name": name, "state_hex": f"{x:#018x}", "ca_step": ca_step(x) == x,
                              "ca_step_fast": ca_step_fast(x) == x, "die": die_value(x)})
    out["both_fixed"] = all(s["ca_step"] and s["ca_step_fast"] for s in out["states"])
    return out


# ----------------------------------------------------------------------------
# driver
# ----------------------------------------------------------------------------
def analyse(mode: str) -> dict:
    sz = SIZES[mode]
    timing: dict[str, float] = {}
    data: dict = {
        "generated": {
            "script": "model/rng_analysis.py", "mode": mode, "python": sys.version.split()[0],
            "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
            "parameters": sz, "commands": COMMANDS,
            "baseline_fmax_mhz": BASELINE_FMAX_MHZ,
            "baseline_fmax_source": "electronic-die/synth/quartus/electronic_die.tan.summary",
        },
        "ca": {
            "width": WIDTH, "neighbourhood": "adr = {cell[i], cell[i-1], cell[i+2], cell[i+1]} (indices mod 64)",
            "lut": list(LUT), "lut_rows": [{"adr": f"{a:04b}", "next": LUT[a]} for a in range(16)],
            "lut_ones": sum(LUT), "die": "die(x) = (x mod 6) + 1",
            "self_bias": {"p_next1_given_cell1": sum(LUT[8:]) / 8, "p_next1_given_cell0": sum(LUT[:8]) / 8,
                          "note": "fraction of LUT rows with next = 1 among rows with cell[i] = 1 / = 0"},
            "mod6_bias": {"two_pow_64_mod_6": (1 << 64) % 6,
                          "note": "residues 0..3 have one more preimage than 4 and 5 among the 2^64 words",
                          "relative_bias": 6 / (1 << 64)},
        },
        "seeds": [],
    }
    for label, seed in SEEDS:
        entry: dict = {"label": label, "seed": seed, "seed_hex": f"{seed:#018x}", "seed_bin": fmt(seed)}
        log(f"seed {label} ({seed:#x}): Brent cycle search, cap {sz['period_cap']:,} hare steps")
        t = time.perf_counter()
        period = brent(seed, sz["period_cap"])
        if period["found"]:
            period["cycle"] = cycle_profile(int(period["cycle_entry_hex"], 16), period["lam"])
            period["time_to_cycle_ms_at_baseline_fmax"] = period["mu"] / (BASELINE_FMAX_MHZ * 1e3)
        entry["period"] = period
        timing[f"period_{label}"] = time.perf_counter() - t
        log(f"  {'cycle: mu=%d lam=%d' % (period['mu'], period['lam']) if period['found'] else 'no cycle within the cap'}")

        log(f"seed {label}: one pass over {sz['draws']:,} states")
        t = time.perf_counter()
        entry["window"] = main_pass(seed, sz["draws"])
        n = sz["draws"]
        if period["found"]:
            entry["window"]["composition"] = {"draws_before_cycle": min(n, period["mu"]),
                                              "draws_on_cycle": max(0, n - period["mu"])}
        timing[f"window_{label}"] = time.perf_counter() - t
        u, i = entry["window"]["uniformity"], entry["window"]["independence"]
        log(f"  chi2 uniformity {u['chi2']:.3f} p={u['p_value']:.3g}; independence {i['chi2']:.3f} p={i['p_value']:.3g}")
        entry["tail"] = None
        if period["found"] and period["mu"] < n and period["mu"] >= MIN_TAIL_DRAWS:
            log(f"seed {label}: the {period['mu']:,} draws before the cycle, analysed on their own")
            t = time.perf_counter()
            entry["tail"] = main_pass(seed, period["mu"])
            timing[f"tail_{label}"] = time.perf_counter() - t
            u = entry["tail"]["uniformity"]
            log(f"  chi2 uniformity {u['chi2']:.3f} p={u['p_value']:.3g}")
        data["seeds"].append(entry)

    log(f"survey: {sz['survey_seeds']} random seeds + 64 single-bit seeds, cap {sz['survey_cap']:,}")
    t = time.perf_counter()
    data["fixed_points"] = fixed_point_checks()
    data["survey"] = survey(sz["survey_seeds"], sz["survey_cap"])
    timing["survey"] = time.perf_counter() - t
    log(f"  random: {data['survey']['random']['found']} found; single-bit: {data['survey']['single_bit']['found']} found")

    log(f"census: exact count of states with f^p(x) = x for p <= {sz['census_max_period']}")
    t = time.perf_counter()
    data["census"] = [census(p) for p in range(1, sz["census_max_period"] + 1)]
    timing["census"] = time.perf_counter() - t
    for c in data["census"]:
        log(f"  p={c['period']}: {c['count']} states")

    timing["total"] = time.perf_counter() - T0
    data["generated"]["timing_s"] = timing
    data["generated"]["elapsed_s"] = timing["total"]
    return data


# ----------------------------------------------------------------------------
# markdown rendering (from the JSON on disk only)
# ----------------------------------------------------------------------------
def fnum(x: float, nd: int = 3) -> str:
    return f"{x:,.{nd}f}"


def fp(p: float) -> str:
    if p < 1e-300:
        return "< 1e-300"
    return f"{p:.3g}" if p < 1e-3 else f"{p:.4f}"


def peq(p: float) -> str:
    """'p = 0.0123' or 'p < 1e-300' for prose."""
    return f"p {fp(p)}" if p < 1e-300 else f"p = {fp(p)}"


def verdict(p: float) -> str:
    return "rejected" if p < 1e-3 else "not rejected"


def table(header: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(out)


def sequences(d: dict) -> list[tuple[str, dict]]:
    """(name, main_pass result) for every analysed draw sequence."""
    out = []
    for e in d["seeds"]:
        out.append((f"{e['label']} seed, {e['window']['draws']:,} draws", e["window"]))
        if e["tail"]:
            out.append((f"{e['label']} seed, {e['tail']['draws']:,} draws before the cycle", e["tail"]))
    return out


def render(d: dict) -> str:
    g = d["generated"]
    sz = g["parameters"]
    ca = d["ca"]
    seeds = d["seeds"]
    course, dense = seeds[0], seeds[1]
    cmd = g["commands"]
    seqs = sequences(d)
    quick_note = " (quick mode: sample sizes divided by about 100)" if g["mode"] == "quick" else ""
    out: list[str] = []
    w = out.append

    w("<!-- Generated by model/rng_analysis.py from build/rng_analysis.json. Do not edit by hand. -->")
    w("# RNG quality analysis: 64-bit cellular-automaton die")
    w("")
    w(f"Generated {g['timestamp_utc']} by `{cmd[g['mode']]}` in {g['elapsed_s']:.1f} s "
      f"(Python {g['python']}, standard library only){quick_note}. Every number below is rendered "
      "from `build/rng_analysis.json`; rerun the command to regenerate both files. `build/` is git-ignored, so "
      "the JSON is not committed: the run is deterministic (the survey seeds come from "
      f"`random.Random({d['survey']['random_generator_seed']})`) and the command recreates it in the time listed "
      "in section 8.")
    w("")

    # ---- summary
    w("## Summary")
    w("")
    cp = course["period"]
    if cp["found"]:
        cyc = cp["cycle"]
        w(f"- **The course seed `{course['seed']}` runs into a cycle of {cyc['length']} states after "
          f"{cp['mu']:,} CA steps** (about {cp['time_to_cycle_ms_at_baseline_fmax']:.1f} ms at the baseline "
          f"{g['baseline_fmax_mhz']} MHz; the die shows the first cycle value after clock edge {cp['mu'] + 2:,}). From then on "
          f"the die repeats the same {cyc['length']} values and "
          f"shows only faces {', '.join(str(k + 1) for k, c in enumerate(cyc['face_counts']) if c)}.")
    else:
        w(f"- The course seed `{course['seed']}` shows no cycle within {cp['hare_steps']:,} Brent steps "
          f"(the first {cp['certified_distinct_steps'] + 1:,} states are distinct).")
    dp = dense["period"]
    if dp["found"]:
        w(f"- The dense seed `{dense['seed_hex']}` runs into a cycle of {dp['lam']:,} states after {dp['mu']:,} CA steps.")
    else:
        w(f"- The dense seed `{dense['seed_hex']}` shows no cycle within {dp['hare_steps']:,} Brent steps: "
          f"its first {dp['certified_distinct_steps'] + 1:,} states (state[0..{dp['certified_distinct_steps']:,}]) are pairwise distinct.")
    ref = dense["window"]
    w(f"- **Even faces are favoured.** The parity of the face is cell 0 of the state, and the CA settles at a "
      f"density of ones of about {ref['bit_balance']['mean']:.3f} rather than 0.5, so P(even face) = "
      f"{ref['uniformity']['parity']['even_face_fraction']:.4f} for the dense seed over {ref['draws']:,} draws "
      f"(chi-square {fnum(ref['uniformity']['chi2'], 1)} on 5 dof, {peq(ref['uniformity']['p_value'])}). "
      f"Within each parity the three faces are consistent with uniform ({peq(ref['uniformity']['odd_faces']['p_value'])} and "
      f"{fp(ref['uniformity']['even_faces']['p_value'])}).")
    pt = ref["independence"]["parity"]
    w(f"- **Consecutive faces are not independent.** P(even | previous even) = {pt['p_even_given_even']:.4f} "
      f"against P(even | previous odd) = {pt['p_even_given_odd']:.4f} (dense seed), because a cell's next value "
      f"is 1 in {int(ca['self_bias']['p_next1_given_cell1'] * 8)} of the 8 LUT rows with cell[i] = 1 but only in "
      f"{int(ca['self_bias']['p_next1_given_cell0'] * 8)} of the 8 rows with cell[i] = 0. The 6x6 "
      f"independence test rejects ({peq(ref['independence']['p_value'])}); the mod-3 residues "
      f"{'show no detectable dependence' if ref['independence']['mod3']['p_value'] >= 1e-3 else 'are dependent as well'} "
      f"({peq(ref['independence']['mod3']['p_value'])}).")
    fixed_hex = sorted({s["state_hex"] for c in d["census"] for s in c["states"] if s["min_period"] == 1})
    pmax = max(c["period"] for c in d["census"])
    sv = d["survey"]
    sb = sv["single_bit"]
    if sv["random"]["found"] == 0 and sb["found"] == 0:
        survey_sentence = (f"none of {sv['random']['seeds']:,} random seeds and 64 single-bit seeds has a cycle with "
                           f"mu + lambda <= {sv['certified_distinct_steps']:,} (Brent capped at {sv['cap']:,} hare "
                           "steps finds every such cycle)")
    else:
        survey_sentence = (f"{sv['random']['found']} of {sv['random']['seeds']:,} random seeds and {sb['found']} of "
                           f"64 single-bit seeds reach a cycle that Brent finds within {sv['cap']:,} hare steps "
                           "(section 6)")
    w(f"- The CA has exactly {len(fixed_hex)} fixed points and no other cycle of length up to {pmax} "
      f"(exhaustive); {survey_sentence}.")
    w("")

    # ---- method
    w("## 1. Method")
    w("")
    w("**The generator.** `rng64` is a one-dimensional cellular automaton (CA) of 64 cells on a ring "
      "(`electronic-die/rtl/*/rng64.*`, `ca_cell.*`). On every rising clock edge with `sel = 1` each cell "
      f"`i` reads the 4-bit address `{ca['neighbourhood']}` and takes its next value from the lookup table "
      f"below; with `sel = 0` it loads its seed bit. The table is balanced ({ca['lut_ones']} ones out of 16 "
      f"entries) but not self-neutral: among the rows with `cell[i] = 1` the next value is 1 in "
      f"{int(ca['self_bias']['p_next1_given_cell1'] * 8)} of 8 cases, among the rows with `cell[i] = 0` in "
      f"{int(ca['self_bias']['p_next1_given_cell0'] * 8)} of 8.")
    w("")
    lut_rows = [[r["adr"], str(r["next"])] for r in ca["lut_rows"]]
    half = len(lut_rows) // 2
    w(table(["adr", "next", "adr ", "next "], [lut_rows[k] + lut_rows[k + half] for k in range(half)]))
    w("")
    w("**The draws.** The die value is `die(x) = (x mod 6) + 1` of the whole 64-bit state. Under the "
      "timing contract of `electronic_die` (docs/verification.md, section 2) the output register is written "
      "at every rising edge `m >= 2` at which `en = 1`, with `die(state[m-2])` (edge 1 only loads the seed). "
      "*`en` held at 1* therefore means that the output shows every CA state exactly once, in order: a run of "
      "N+1 clocks yields the N draws `die(state[0]), ..., die(state[N-1])`, where `state[0]` is the seed and "
      "draw `j` appears after edge `j+2`. Counts of steps below are state indices: the CA holds `state[j]` after "
      "edge `j+1`. Any other `en` pattern "
      "only selects a subsequence of this same deterministic sequence, because the CA free-runs regardless "
      "of `en`. All draws here are taken that way, with the states produced by the reference model "
      "`model/ca_rng.py` (`ca_step_fast`, checked against the bit-by-bit `ca_step` by "
      f"`{cmd['selftest']}`). Because `x mod 2` is cell 0, the face is even exactly when cell 0 is 1; "
      "`x mod 3` depends on every cell (2^k mod 3 alternates 1, 2).")
    w("")
    w(f"**Seeds.** `{course['seed']}` (`{course['seed_hex']}`, the course run and the default `SEED` "
      f"parameter) and `{dense['seed_hex']}` (the dense seed also used by `make test`). Each seed gets the "
      f"period search and the full set of statistics over {sz['draws']:,} draws; when the period search finds "
      "a cycle inside that window, the draws before the cycle are also analysed on their own.")
    w("")
    w("**Statistics.** The null hypothesis throughout is *independent, uniformly distributed faces*. "
      "Chi-square p-values are computed in pure Python as the regularised upper incomplete gamma "
      "function `Q(dof/2, chi2/2)`: `Q(1/2, y) = erfc(sqrt(y))`, `Q(1, y) = exp(-y)`, then "
      "`Q(a+1, y) = Q(a, y) + y^a e^-y / Gamma(a+1)` (`chi2_sf` in `model/rng_analysis.py`); values below "
      "1e-300 are printed as such. The independence test is the contingency chi-square on the 6x6 matrix "
      "of overlapping consecutive pairs, i.e. the Anderson-Goodman test of a zero-order against a "
      "first-order Markov chain, with (6-1)^2 = 25 degrees of freedom; the same test is applied to the face "
      "parity (2x2, 1 dof) and to `x mod 3` (3x3, 4 dof). Autocorrelation at lag L is "
      "`r_L = sum_j (x_j - m)(x_{j+L} - m) / sum_j (x_j - m)^2` with `m` the sample mean; for i.i.d. "
      "draws `r_L` has standard error `1/sqrt(N)`. The period search is Brent's cycle-finding algorithm "
      "on the state sequence; with the tortoise parked at positions `2^k - 1`, a run of `cap` hare steps "
      "without a match proves that `state[0..2^j]` are pairwise distinct for the largest `j` with "
      "`2^(j+1) - 1 <= cap` (every cycle with `mu + lambda <= 2^j` would have been found by hare step "
      "`2^j - 1 + lambda <= 2^(j+1) - 1`). Every step of a found cycle is re-verified with both `ca_step` and "
      "`ca_step_fast` (`cycle_profile`).")
    w("")
    w(f"A 64-bit word folded by `mod 6` is not perfectly uniform: `2^64 mod 6 = {ca['mod6_bias']['two_pow_64_mod_6']}`, "
      f"so faces 1-4 have one more preimage than faces 5-6; the relative bias is `6 / 2^64 = "
      f"{ca['mod6_bias']['relative_bias']:.2e}` and is invisible at any sample size used here.")
    w("")

    # ---- uniformity
    w("## 2. Uniformity of the six faces")
    w("")
    for e in seeds:
        u = e["window"]["uniformity"]
        comp = e["window"].get("composition")
        w(f"Seed `{e['seed_hex']}` ({e['label']}), {u['draws']:,} consecutive draws, expected "
          f"{u['expected_per_face']:,.1f} per face"
          + (f"; {comp['draws_before_cycle']:,} of these draws precede the cycle and {comp['draws_on_cycle']:,} "
             f"repeat its {e['period']['lam']} values" if comp else "") + ":")
        w("")
        rows = [[str(k + 1), f"{c:,}", f"{dev * 100:+.3f} %"] for k, (c, dev) in enumerate(zip(u["counts"], u["relative_deviation"]))]
        w(table(["face", "count", "deviation from expected"], rows))
        w("")
        w(f"chi-square = {fnum(u['chi2'])} with {u['dof']} degrees of freedom, {peq(u['p_value'])}: "
          f"uniformity {verdict(u['p_value'])} at the 0.1 % level.")
        w("")
        if e["tail"]:
            ut = e["tail"]["uniformity"]
            w(f"The same seed, only the {ut['draws']:,} draws before the cycle (expected {ut['expected_per_face']:,.1f} per face):")
            w("")
            rows = [[str(k + 1), f"{c:,}", f"{dev * 100:+.3f} %"] for k, (c, dev) in enumerate(zip(ut["counts"], ut["relative_deviation"]))]
            w(table(["face", "count", "deviation from expected"], rows))
            w("")
            w(f"chi-square = {fnum(ut['chi2'])} with {ut['dof']} degrees of freedom, {peq(ut['p_value'])}: "
              f"uniformity {verdict(ut['p_value'])} at the 0.1 % level.")
            w("")
    w("Parity decomposition. The face is even exactly when cell 0 of the state is 1, so the even-face count "
      "equals the number of states with cell 0 set (checked). The six-face chi-square splits (approximately, "
      "for Pearson's statistic) into the parity (1 dof), the three odd faces given odd (2 dof) and the three "
      "even faces given even (2 dof); `x mod 3` (2 dof) is listed as well:")
    w("")
    rows = []
    for name, m in seqs:
        u = m["uniformity"]
        rows.append([name, f"{u['parity']['even_face_fraction']:.5f}" + ("" if u["parity"]["consistent"] else " (MISMATCH)"),
                     f"{fnum(u['parity']['chi2'], 1)} / {fp(u['parity']['p_value'])}",
                     f"{fnum(u['odd_faces']['chi2'], 2)} / {fp(u['odd_faces']['p_value'])}",
                     f"{fnum(u['even_faces']['chi2'], 2)} / {fp(u['even_faces']['p_value'])}",
                     f"{fnum(u['mod3']['chi2'], 2)} / {fp(u['mod3']['p_value'])}"])
    w(table(["sequence", "P(even face)", "parity chi2 / p (1 dof)", "odd faces chi2 / p (2 dof)",
             "even faces chi2 / p (2 dof)", "x mod 3 chi2 / p (2 dof)"], rows))
    w("")
    w("![Face counts for both seeds and the lag autocorrelation](img/die_histogram.png)")
    w("")
    w(f"Figure: `{cmd['plot']}` (matplotlib, not part of the standard-library path).")
    w("")

    # ---- independence
    w("## 3. Independence of consecutive draws")
    w("")
    for e in seeds:
        ind = e["window"]["independence"]
        w(f"Transition counts `from` (row) -> `to` (column), seed `{e['seed_hex']}` ({e['label']}), "
          f"{ind['pairs']:,} consecutive pairs (about {ind['pairs'] / 36:,.0f} per cell if independent):")
        w("")
        rows = [[str(i + 1)] + [f"{v:,}" for v in ind["matrix"][i]] + [f"{ind['row_sums'][i]:,}"] for i in range(FACES)]
        w(table(["from \\ to"] + [str(j + 1) for j in range(FACES)] + ["row sum"], rows))
        w("")
    rows = []
    for name, m in seqs:
        ind = m["independence"]
        pt, m3 = ind["parity"], ind["mod3"]
        rows.append([name, f"{fnum(ind['chi2'], 1)} / {fp(ind['p_value'])}",
                     f"{pt['p_even_given_even']:.4f}", f"{pt['p_even_given_odd']:.4f}", f"{pt['phi']:+.4f}",
                     f"{fnum(m3['chi2'], 2)} / {fp(m3['p_value'])}"])
    w(table(["sequence", "6x6 chi2 / p (25 dof)", "P(even | prev even)", "P(even | prev odd)", "parity phi",
             "mod-3 3x3 chi2 / p (4 dof)"], rows))
    w("")
    w("Lag autocorrelation of the die-value sequence (centred, normalised), with the 95 % band "
      "+/-1.96/sqrt(N) for independent draws, followed by the autocorrelation of the face parity "
      "(1 = even face) at the same lags:")
    w("")
    hdr = ["lag"] + [name for name, _ in seqs]
    rows = [[str(k + 1)] + [f"{m['autocorrelation']['lags'][k]['r']:+.5f}" for _, m in seqs] for k in range(8)]
    rows.append(["95 % band"] + [f"+/-{m['autocorrelation']['band95']:.5f}" for _, m in seqs])
    for k in range(8):
        rows.append([f"parity, lag {k + 1}"] + [f"{m['autocorrelation']['parity_lags'][k]['r']:+.5f}" for _, m in seqs])
    rows.append(["mean (ideal 3.5)"] + [f"{m['autocorrelation']['mean']:.4f}" for _, m in seqs])
    rows.append(["variance (ideal 2.9167)"] + [f"{m['autocorrelation']['variance']:.4f}" for _, m in seqs])
    w(table(hdr, rows))
    w("")

    # ---- period
    w("## 4. Period")
    w("")
    rows = []
    for e in seeds:
        pr = e["period"]
        if pr["found"]:
            res = f"cycle found: tail mu = {pr['mu']:,}, cycle length lambda = {pr['lam']:,}"
            cert = f"period {pr['lam']:,} after {pr['mu']:,} CA steps"
        else:
            res = f"no cycle within {pr['hare_steps']:,} hare steps"
            cert = f"state[0..{pr['certified_distinct_steps']:,}] pairwise distinct (mu + lambda > {pr['certified_distinct_steps']:,})"
        dpx = e["window"]["distinct_prefix"]
        rows.append([f"`{e['seed_hex']}`", f"{pr['cap']:,}", res, cert,
                     f"{dpx['distinct']:,} of {dpx['states']:,}" + (" (all distinct)" if dpx["all_distinct"] else "")])
    w(table(["seed", "cap (hare steps)", "Brent result", "established", "distinct states in the draw window (set check)"], rows))
    w("")
    for e in seeds:
        pr = e["period"]
        if not pr["found"]:
            continue
        cyc = pr["cycle"]
        w(f"The cycle of seed `{e['seed_hex']}` is entered at `{cyc['entry_hex']}` = state[{pr['mu']:,}], i.e. after "
          f"{pr['mu']:,} CA steps: the CA holds it after clock edge {pr['mu'] + 1:,} and the die shows its value after "
          f"edge {pr['mu'] + 2:,} (about {pr['time_to_cycle_ms_at_baseline_fmax']:.1f} ms at {g['baseline_fmax_mhz']} MHz, "
          "the baseline fmax). "
          + (f"It is a travelling pattern: {cyc['shift']['description']}, so the pattern returns to itself after "
             f"{cyc['length']} steps. " if cyc["shift"] else "")
          + f"Its states hold {cyc['popcount_min']}-{cyc['popcount_max']} ones (mean {cyc['popcount_mean']:.1f} of 64). "
          f"The die values along one period are `{cyc['die_sequence']}`; face counts per period "
          f"{', '.join(f'{k + 1}: {c}' for k, c in enumerate(cyc['face_counts']))}"
          + (f"; faces {', '.join(map(str, cyc['faces_absent']))} never occur." if cyc["faces_absent"] else "."))
        w("")
    w("The state space has 2^64 states, so the true period of any orbit is below 2^64; only what the table "
      "states has been established.")
    w("")

    # ---- bit balance
    w("## 5. Per-cell bit balance")
    w("")
    rows = []
    for name, m in seqs:
        bb = m["bit_balance"]
        rows.append([name, f"{bb['min']:.5f} (cell {bb['argmin']})", f"{bb['max']:.5f} (cell {bb['argmax']})",
                     f"{bb['mean']:.5f}", f"{bb['std']:.5f}", f"{bb['sd_iid']:.5f}", str(bb["cells_beyond_3sd"]),
                     f"{bb['overall_ones_fraction']:.5f}"])
    w(table(["sequence", "min", "max", "mean over cells", "sd over cells", "fair-coin sd", "cells beyond 3 sd",
             "ones in the whole state"], rows))
    w("")
    for e in seeds:
        bb = e["window"]["bit_balance"]
        w(f"Fraction of ones in each of the 64 cells, seed `{e['seed_hex']}` ({e['label']}), {bb['steps']:,} states:")
        w("")
        rows = [["cells " + f"{8 * r}-{8 * r + 7}"] + [f"{bb['per_cell_ones_fraction'][8 * r + c]:.4f}" for c in range(8)] for r in range(8)]
        w(table(["", "+0", "+1", "+2", "+3", "+4", "+5", "+6", "+7"], rows))
        w("")
        w("Worst cells (largest |fraction - 0.5|, z in fair-coin standard deviations): "
          + ", ".join(f"cell {c['cell']} = {c['ones_fraction']:.5f} (z = {c['z']:+.1f})" for c in bb["worst_cells"]) + ".")
        w("")

    # ---- fixed points and short cycles
    w("## 6. Fixed points and short cycles")
    w("")
    fx = d["fixed_points"]
    w(f"`LUT[0000] = {fx['lut_0000']}` and `LUT[1111] = {fx['lut_1111']}`, so the all-zero and all-one states map to "
      f"themselves; `LUT[0101] = {fx['lut_0101']}` and `LUT[1010] = {fx['lut_1010']}` do the same for the two "
      "alternating patterns, in which every cell sees `{cell[i], cell[i-1], cell[i+2], cell[i+1]}` = its own value, "
      "its complement, its own value, its complement. Checked with both `ca_step` and `ca_step_fast`:")
    w("")
    w(table(["state", "fixed point", "die value"],
            [[f"{s['name']} `{s['state_hex']}`", "yes" if s["ca_step"] and s["ca_step_fast"] else "NO", str(s["die"])] for s in fx["states"]]))
    w("")
    w("Exhaustive census of short orbits (transfer-matrix count of the states `x` with `f^p(x) = x`; "
      "a state of minimal period `q` is counted for every `p` that `q` divides):")
    w("")
    rows = []
    for c in d["census"]:
        listed = ", ".join(f"`{s['state_hex']}` (period {s['min_period']}, die {s['die']})" for s in c["states"]) if c["listed"] else "-"
        if c["count"] > c["listed"]:
            listed += f" ... ({c['count'] - c['listed']} more not listed)"
        rows.append([str(c["period"]), f"{c['window_cells']} cells / {c['overlap_states']:,} window states", str(c["count"]), listed])
    w(table(["p", "window / graph size", "states with f^p(x) = x", "states"], rows))
    w("")
    new_cycles = [s for c in d["census"] for s in c["states"] if s["min_period"] > 1]
    w(f"The CA has exactly {len(fixed_hex)} fixed points ({', '.join(f'`{h}`' for h in fixed_hex)}) and "
      + ("no" if not new_cycles else f"{len({s['state_hex'] for s in new_cycles})} states on")
      + f" cycles of length 2 to {pmax}. The alternating patterns are fixed because `LUT[0101] = 0` and "
      "`LUT[1010] = 1`.")
    w("")
    w(f"Survey: {sv['random']['seeds']:,} random seeds (`random.Random({sv['random_generator_seed']})`) and the "
      f"64 single-bit seeds, each run with Brent capped at {sv['cap']:,} hare steps (a seed that finds no cycle "
      f"has `mu + lambda > {sv['certified_distinct_steps']:,}`):")
    w("")

    def grp(name: str, s: dict) -> list[str]:
        hist = ", ".join(f"lambda = {k}: {v}" for k, v in s["cycle_length_histogram"].items()) or "-"
        fps = ", ".join(f"`{k}` x{v}" for k, v in s["fixed_points_reached"].items()) or "-"
        mu = f"{s['mu_min']:,} .. {s['mu_max']:,} (mean {s['mu_mean']:,.1f})" if s["found"] else "-"
        return [name, str(s["seeds"]), str(s["found"]), str(s["not_found"]), hist, fps, mu]

    w(table(["seeds", "n", "cycle found", "no cycle", "cycle lengths", "fixed points reached", "tail mu"],
            [grp("random", sv["random"]), grp("single-bit", sv["single_bit"])]))
    w("")
    w(f"The 64 single-bit seeds are rotations of one another and the rule is the same at every cell, so they "
      f"form one rotation class; their results are {'identical' if sb['all_identical'] else 'NOT identical (unexpected)'}."
      + (f" The class reaches a cycle of length {sb['found_cycles'][0]['lam']:,} after a tail of "
         f"{sb['found_cycles'][0]['mu']:,} steps, entering at `{sb['found_cycles'][0]['cycle_entry_hex']}`." if sb["found"] else ""))
    w("")

    # ---- known weaknesses
    w("## 7. Known weaknesses")
    w("")
    k = 1
    if cp["found"]:
        cyc = cp["cycle"]
        w(f"{k}. **The shipped seed has a period of {cyc['length']}.** With the default `SEED = {course['seed']}` the "
          f"CA enters a {cyc['length']}-state cycle after {cp['mu']:,} CA steps "
          f"(about {cp['time_to_cycle_ms_at_baseline_fmax']:.1f} ms at {g['baseline_fmax_mhz']} MHz). After that the "
          f"die is a fixed loop of {cyc['length']} values"
          + (f" that never shows faces {', '.join(map(str, cyc['faces_absent']))}" if cyc["faces_absent"] else "")
          + f"; over the {course['window']['draws']:,}-draw window the faces are far from uniform "
          f"(chi-square {fnum(course['window']['uniformity']['chi2'], 0)} on 5 dof). The {cp['mu']:,} draws "
          f"before the cycle behave like the dense seed below. The course testbenches only cover the first "
          "few hundred clocks and cannot see this; the fix is a seed with a verified long orbit (or a "
          "different rule).")
        k += 1
    fx_die = {s["state_hex"]: s["die"] for c in d["census"] for s in c["states"] if s["min_period"] == 1}
    w(f"{k}. **Even faces are favoured by about {(ref['uniformity']['parity']['even_face_fraction'] - 0.5) * 100:.1f} "
      f"percentage points.** The face parity is cell 0 of the state, and the rule drives the density of ones "
      f"to about {ref['bit_balance']['mean']:.3f} in every cell ({ref['bit_balance']['cells_beyond_3sd']} of the "
      f"{WIDTH} cells of the dense seed lie beyond 3 fair-coin standard deviations), so "
      f"P(even face) = {ref['uniformity']['parity']['even_face_fraction']:.4f} and the six-face chi-square "
      f"rejects uniformity ({peq(ref['uniformity']['p_value'])}) although the three faces within each parity "
      f"are consistent with uniform ({peq(ref['uniformity']['odd_faces']['p_value'])} and {fp(ref['uniformity']['even_faces']['p_value'])}). "
      "Folding the word before the mod 6 (for example XOR of the two 32-bit halves) would make the face parity "
      "depend on several cells instead of cell 0 alone; that is a design change outside this measurement and is "
      "not implemented or tested here.")
    k += 1
    w(f"{k}. **Consecutive faces are dependent through their parity.** Under the rule a cell keeps its current "
      f"value in {round(8 * ca['self_bias']['p_next1_given_cell1'])} of the 8 LUT rows when it is 1 and in "
      f"{round(8 * (1 - ca['self_bias']['p_next1_given_cell0']))} of the 8 rows when it is 0 (probability "
      f"{ca['self_bias']['p_next1_given_cell1']:.3f} for a uniformly random neighbourhood), so the parity of "
      f"consecutive draws is correlated: for the dense seed "
      f"P(even | previous even) = {pt['p_even_given_even']:.4f}, P(even | previous odd) = "
      f"{pt['p_even_given_odd']:.4f}, phi = {pt['phi']:+.4f}, and the 6x6 independence test rejects "
      f"(chi-square {fnum(ref['independence']['chi2'], 0)} on 25 dof). The `x mod 3` residues of consecutive "
      f"draws {'show no detectable dependence' if ref['independence']['mod3']['p_value'] >= 1e-3 else 'are dependent as well'} "
      f"({peq(ref['independence']['mod3']['p_value'])}), and the linear lag-1 autocorrelation of the face "
      f"values is only {ref['autocorrelation']['lags'][0]['r']:+.4f}, because the dependence sits in the parity bit "
      f"rather than in the magnitude. The parity autocorrelation is {ref['autocorrelation']['parity_lags'][0]['r']:+.4f} "
      f"at lag 1, {ref['autocorrelation']['parity_lags'][1]['r']:+.4f} at lag 2 and still up to "
      f"{max(abs(x['r']) for x in ref['autocorrelation']['parity_lags'][2:]):.4f} in magnitude at lags 3-8, so "
      "thinning the draws with `en` does not remove the dependence.")
    k += 1
    w(f"{k}. **{len(fixed_hex)} stuck seeds.** The states {', '.join(f'`{h}` (die {fx_die[h]})' for h in fixed_hex)} "
      "are fixed points, so a die built with one of them as `SEED` (or an un-loaded, all-zero seed register) "
      f"shows the same face forever. The exhaustive census finds no other cycle of length up to {pmax}, and in the "
      f"survey {sv['random']['found']} of the {sv['random']['seeds']:,} random seeds and {sb['found']} of the 64 "
      f"single-bit seeds have a cycle with mu + lambda <= {sv['certified_distinct_steps']:,} (the bound that Brent "
      f"capped at {sv['cap']:,} hare steps certifies; longer tails or cycles are not excluded), so as far as this "
      "survey can tell the fixed points are reached only by seeding them directly.")
    k += 1
    w(f"{k}. **Fully deterministic and predictable.** The sequence depends only on the compile-time `SEED`; it is "
      "identical after every power-up, and `en` only chooses which positions of that one sequence are shown. "
      "The whole state is visible as 64 bits of the design and the rule is public, so the next face is "
      "computable from the current state: the generator is a pseudo-random pattern generator, not a source "
      "of entropy and not a cryptographic generator.")
    k += 1
    w(f"{k}. **Periods are known only for the seeds tested.** The dense seed is certified repeat-free for "
      f"{dp.get('certified_distinct_steps', dp.get('mu', 0) + dp.get('lam', 0) - 1) + 1:,} states but its period is not known; "
      f"the course seed shows that an innocent-looking seed can collapse after a few hundred thousand steps, and "
      "no bound applies to seeds that were not tested.")
    k += 1
    w(f"{k}. **What the tests do not show.** With {ref['draws']:,} draws a face bias below about 0.1 % of the "
      "expected count is not detectable, the statistics measure only first-order uniformity and first-order "
      "dependence (plus lags up to 8), and no battery such as TestU01 or Dieharder was run.")
    w("")

    # ---- commands and run time
    w("## 8. Commands and run time")
    w("")
    w(table(["purpose", "command"], [
        ["full analysis (this file)", f"`{cmd['full']}`"],
        ["smoke run, sample sizes / 100", f"`{cmd['quick']}`"],
        ["re-render the markdown from the JSON", f"`{cmd['render_only']}`"],
        ["check ca_step_fast against ca_step", f"`{cmd['selftest']}`"],
        ["figure", f"`{cmd['plot']}`"],
    ]))
    w("")
    tm = g["timing_s"]
    w(table(["phase", "seconds"], [[k2.replace("_", " "), f"{v:.1f}"] for k2, v in tm.items()]))
    w("")
    w(f"Parameters of this run: {', '.join(f'{k2} = {v:,}' for k2, v in sz.items())}; "
      f"baseline fmax {g['baseline_fmax_mhz']} MHz from `{g['baseline_fmax_source']}`.")
    w("")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--md", required=True, help="markdown report to write")
    p.add_argument("--json", required=True, help="JSON results to write (and to read back for rendering)")
    p.add_argument("--quick", action="store_true", help="sample sizes divided by about 100")
    p.add_argument("--render-only", action="store_true", help="only render --md from an existing --json")
    args = p.parse_args(argv)

    if not args.render_only:
        data = analyse("quick" if args.quick else "full")
        os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=1)
            fh.write("\n")
        log(f"wrote {args.json}")
        del data
    with open(args.json, "r", encoding="utf-8") as fh:  # render from disk, never from memory
        loaded = json.load(fh)
    os.makedirs(os.path.dirname(os.path.abspath(args.md)), exist_ok=True)
    with open(args.md, "w", encoding="utf-8") as fh:
        fh.write(render(loaded))
    log(f"wrote {args.md}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
