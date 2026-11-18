"""M01b: move each speaker change to the nearest real pause in the transcript.

The offline diarizer finds the right speakers but places turn changes a little off (M01: 95% of its wrongly
attributed words are within 1 s of a turn change). People rarely change turns mid-word or without a breath, so for
every place where the label changes between two consecutive words, the change is moved to the longest gap between
words within `window` seconds of where the diarizer put it. window=0 leaves the labels as they were.
"""


def snap(words, window):
    """words: dicts with s, e, spk (in time order after sorting). Returns a relabelled copy."""
    if window <= 0 or len(words) < 2:
        return [dict(w) for w in words]
    ws = sorted((dict(w) for w in words), key=lambda w: w["s"])
    i = 1
    while i < len(ws):
        if ws[i]["spk"] == ws[i - 1]["spk"]:
            i += 1
            continue
        before, after = ws[i - 1]["spk"], ws[i]["spk"]
        t = (ws[i - 1]["e"] + ws[i]["s"]) / 2
        # Candidate split points j (the new turn starts at word j), within the window and inside the two runs.
        lo = i
        while lo - 1 > 0 and ws[lo - 1]["spk"] == before and t - ws[lo - 1]["s"] <= window:
            lo -= 1
        hi = i
        while hi + 1 < len(ws) and ws[hi]["spk"] == after and ws[hi]["e"] - t <= window:
            hi += 1
        best = max(range(lo, hi + 1), key=lambda j: (ws[j]["s"] - ws[j - 1]["e"], -abs(j - i)))
        for k in range(lo, hi + 1):
            if k < len(ws) and ws[k]["spk"] in (before, after):
                ws[k]["spk"] = before if k < best else after
        i = max(best, i) + 1
    return ws
