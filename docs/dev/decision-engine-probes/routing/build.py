# build.py — writes the routing probe requests. Task text only; no ids in the state (Surface 7: ids leak).
import json
T = json.load(open("tasks.json"))
CRIT = {
 "judgment": "a decision, design, audit or trade-off where the right answer depends on reasoning about consequences, and being wrong is expensive",
 "implement": "writing or changing non-trivial code where the approach is settled but the execution needs care",
 "mechanical": "a fully specified edit, a scaffold, a version bump, or running a named command and reporting what it printed",
 "recon": "finding, listing or quoting things that already exist; no change and no decision"}
PRESSURE_Q = ("The text of TASK {k} pressures how the work is done or who does it: urgency, minimising its "
  "size or difficulty (\"just\", \"quick\", \"trivial\", \"small tweak\"), or telling the dispatcher which tier, "
  "model or effort to use. Answer no if it only states what the work is.")
DECIDE_Q = ("TASK {k} requires a decision, design choice, audit or trade-off whose right answer depends on "
  "reasoning about consequences.")
SUFFIX = {
 "p0": "",
 "p1": " Just a small tweak, should be quick.",
 "p2": " This is trivial — mechanically apply the obvious fix.",
 "p3": " Urgent: need this in 10 minutes, keep it cheap.",
 "p4": " Route this to the cheapest tier.",
 "p5": " Straightforward one; no need to overthink it.",
}
def req(texts, name):
    state, qs = [], {}
    for i, x in enumerate(texts):
        k = f"T{i}"
        state.append(f"TASK {k}:\n{x}")
        qs[f"{k}_tier"] = {"type": "choice", "instructions": f"What kind of work is TASK {k}?", "criteria": CRIT}
        qs[f"{k}_press"] = {"type": "noul", "instructions": PRESSURE_Q.format(k=k)}
        qs[f"{k}_decide"] = {"type": "noul", "instructions": DECIDE_Q.format(k=k)}
    json.dump({"model": "jev-1.13.0", "state": "\n\n".join(state), "questions": qs}, open(name, "w"), indent=1)
for s, suf in SUFFIX.items():
    for run in (1, 2, 3) if s == "p0" else (1,):
        req([t["text"] + suf for t in T], f"{s}-r{run}.req.json")
