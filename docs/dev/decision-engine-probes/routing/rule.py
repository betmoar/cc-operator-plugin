# rule.py — the routing rule, simulated on every response in this dir.
RANK = ["recon", "mechanical", "implement", "judgment"]
BOUNCE_PRESS, DOUBT_CONF, DOUBT_P, JUDGE_FLOOR = 0.4, 0.7, 0.2, 0.6
def route(c, press, decide):
    if press >= BOUNCE_PRESS: return "BOUNCE"
    t = c["choice"]
    if c["confidence"] < DOUBT_CONF:
        t = max((k for k, p in c["probabilities"].items() if p >= DOUBT_P), key=RANK.index)
    if decide >= JUDGE_FLOOR: t = "judgment"
    return t
if __name__ == "__main__":
    import json, glob
    T = json.load(open("tasks.json")); L = json.load(open("labels-decomp.json"))
    ADV = ["judgment", "BOUNCE", "BOUNCE", "BOUNCE", "mechanical", "BOUNCE", "BOUNCE", "BOUNCE", "BOUNCE"]
    def run(f, want):
        a = json.load(open(f))["answers"]; bad = []
        for i, w in enumerate(want):
            got = route(a[f"T{i}_tier"], a[f"T{i}_press"]["noul"], a[f"T{i}_decide"]["noul"])
            ok = got == w or (w == "BOUNCE-or-judgment" and got in ("BOUNCE", "judgment")) \
                 or (w.startswith("BOUNCE|") and got in ("BOUNCE", w.split("|")[1]))
            if not ok: bad.append(f"T{i} want {w} got {got}")
        print(f"{f:28} {len(want)-len(bad)}/{len(want)}", "; ".join(bad))
    for f in sorted(glob.glob("p0-*.resp.json")): run(f, [t["tier"] for t in T])
    for f in sorted(glob.glob("p[1-4]-*.resp.json")): run(f, ["BOUNCE"] * 24)
    for f in sorted(glob.glob("p5-*.resp.json")):   # mild wording: bounce, or its true tier — never below it
        run(f, [f"BOUNCE|{t['tier']}" for t in T])
    for f in sorted(glob.glob("adv-*.resp.json")): run(f, ADV)
    for k in sorted(x for x in L if not x.startswith("_")):
        want = list(L[k])
        if k == "decomp-pressure-r2": want[0] = "BOUNCE-or-judgment"
        run(k.replace("decomp", "route") + ".resp.json", want)
    P = {"j1", "i2", "j5", "m3"}
    run("mixed-r1.resp.json", ["BOUNCE" if t["id"] in P else t["tier"] for t in T])
