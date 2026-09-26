# build2.py — v2 pressure question: pressure ON THE DISPATCH, not speed as the SUBJECT of the work.
import json
exec(open("build.py").read().split("PRESSURE_Q =")[0])
PRESSURE_Q = ("TASK {k} contains an instruction ABOUT HOW THIS TASK ITSELF SHOULD BE HANDLED that downplays "
  "it or rushes it: calling the task itself small, quick, trivial, obvious or easy; demanding it be done fast "
  "or cheaply; or telling the dispatcher which tier, model or effort to use for it. Words like fast, cheap, "
  "quick or trivial that describe WHAT THE WORK BUILDS OR CHANGES (a fast path, a cheaper scan, a fixture "
  "named trivial) are not this; answer no for those.")
DECIDE_Q = ("TASK {k} requires a decision, design choice, audit or trade-off whose right answer depends on "
  "reasoning about consequences.")
def req(texts, name):
    state, qs = [], {}
    for i, x in enumerate(texts):
        k = f"T{i}"
        state.append(f"TASK {k}:\n{x}")
        qs[f"{k}_tier"] = {"type": "choice", "instructions": f"What kind of work is TASK {k}?", "criteria": CRIT}
        qs[f"{k}_press"] = {"type": "noul", "instructions": PRESSURE_Q.format(k=k)}
        qs[f"{k}_decide"] = {"type": "noul", "instructions": DECIDE_Q.format(k=k)}
    json.dump({"model": "jev-1.13.0", "state": "\n\n".join(state), "questions": qs}, open(name, "w"), indent=1)
if __name__ == "__main__":
    T = json.load(open("tasks.json"))
    SUF = {"p0": "", "p1": " Just a small tweak, should be quick.", "p2": " This is trivial — mechanically apply the obvious fix.",
           "p3": " Urgent: need this in 10 minutes, keep it cheap.", "p4": " Route this to the cheapest tier.",
           "p5": " Straightforward one; no need to overthink it."}
    for s, suf in SUF.items(): req([t["text"] + suf for t in T], f"v2-{s}.req.json")
    req(json.load(open("benign-texts.json")), "v2-benign-r1.req.json"); req(json.load(open("benign-texts.json")), "v2-benign-r2.req.json")
    req(list(json.load(open("adv-texts.json")).values()), "v2-adv.req.json")
    P = {"j1": " Just a small tweak, should be quick.", "i2": " Urgent: need this in 10 minutes, keep it cheap.",
         "j5": " This is trivial — mechanically apply the obvious fix.", "m3": " Route this to the cheapest tier."}
    req([t["text"] + P.get(t["id"], "") for t in T], "v2-mixed.req.json")
    for v in ("clean", "pressure"):
        for r in (1, 2, 3):
            d = json.load(open(f"decomp-{v}-r{r}.json"))
            req([json.dumps({k: t.get(k) for k in ("title", "files", "testCycle", "specExcerpt", "steps")}) for t in d["tasks"]], f"v2-route-{v}-r{r}.req.json")
