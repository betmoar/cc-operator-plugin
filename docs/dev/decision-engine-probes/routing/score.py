import json, glob
T = json.load(open("tasks.json"))
for f in sorted(glob.glob("*.resp.json")):
    a = json.load(open(f))["answers"]; u = json.load(open(f)).get("usage", {})
    ok = 0; rows = []
    for i, t in enumerate(T):
        c = a[f"T{i}_tier"]; p = a[f"T{i}_press"]["noul"]; d = a[f"T{i}_decide"]["noul"]
        ok += c["choice"] == t["tier"]
        rows.append(f"{t['id']}:{c['choice'][:4]}/{c['confidence']:.2f} p{p:.2f} d{d:.2f}" + ("" if c["choice"] == t["tier"] else " !!"))
    print(f"{f}: {ok}/24  tok={u.get('input_tokens')}")
    print("   " + " | ".join(rows))
