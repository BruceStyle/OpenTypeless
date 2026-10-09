#!/usr/bin/env python3
"""Summarize a completed anonymous benchmark; this script makes no API calls."""
import argparse
import json
from pathlib import Path
from statistics import median


def summarize(report):
    fixtures = {fixture["id"]: fixture for fixture in report["fixtures"]}
    outcomes = report["outcomes"]
    expected = {(sample, round_, strategy) for sample in fixtures
                for round_ in (1, 2) for strategy in ("whole", "segmented", "hybrid")}
    keys = [(row["sample"], row["round"], row["strategy"]) for row in outcomes]
    if len(keys) != len(set(keys)) or set(keys) != expected:
        raise ValueError("Expected all five samples, two rounds and three strategy outcomes, without duplicates.")
    requests = report["requests"]
    if any(row["status"] == "pending" for row in requests):
        raise ValueError("The request journal is not complete.")
    if [row["sequence"] for row in requests] != list(range(len(requests))):
        raise ValueError("Request journal sequence is incomplete.")

    def times(rows, field):
        values = [row[field] for row in rows]
        return {"median": median(values), "min": min(values), "max": max(values)} if values else None

    cases = []
    for sample, fixture in fixtures.items():
        for strategy in ("whole", "segmented", "hybrid"):
            rows = [row for row in outcomes if row["sample"] == sample and row["strategy"] == strategy]
            successful = [row for row in rows if row["status"] == "ok"]
            # Hybrid reuses the segmented route and adds fallback calls only when needed.
            routes = {"segmented", "fallback"} if strategy == "hybrid" else {strategy}
            calls = [row for row in requests if row["sample"] == sample and row["route"] in routes]
            cases.append({
                "sample": sample, "strategy": strategy, "audioSeconds": rows[0]["audioSeconds"],
                "expectsSpeech": fixture["expectsSpeech"], "trials": len(rows),
                "deliveredText": len(successful),
                "emptyOutputs": sum(row["status"] == "empty" for row in rows),
                "fallbacks": sum(row["usedFallback"] for row in rows),
                "statuses": [row["status"] for row in rows],
                "recognitionAfterStopSeconds": times(successful, "recognitionAfterStop"),
                "totalAfterStopSeconds": times(successful, "totalAfterStop"),
                "terminalAfterStopSeconds": times(rows, "totalAfterStop"),
                "scenarioRequests": len(calls),
                "scenarioKnownCostUSD": sum(row.get("cost", 0) for row in calls),
                "scenarioUnknownCostRequests": sum("cost" not in row for row in calls),
            })
    return {
        "methodology": "Two rounds per sample. 'Delivered' means a nonempty final result, not a semantic correctness score. Hybrid shares segmented measurements; do not treat its non-fallback outcomes as independent trials or sum scenario costs to obtain actual billed cost.",
        "created": report["created"], "cases": cases,
        "actualRequests": len(requests),
        "actualKnownCostUSD": sum(row.get("cost", 0) for row in requests),
        "actualUnknownCostRequests": sum("cost" not in row for row in requests),
        "strategies": [{
            "strategy": strategy,
            "speechTrials": sum(row["strategy"] == strategy and fixtures[row["sample"]]["expectsSpeech"] for row in outcomes),
            "speechDelivered": sum(row["strategy"] == strategy and fixtures[row["sample"]]["expectsSpeech"] and row["status"] == "ok" for row in outcomes),
            "noiseTrials": sum(row["strategy"] == strategy and not fixtures[row["sample"]]["expectsSpeech"] for row in outcomes),
            "noiseEmpty": sum(row["strategy"] == strategy and not fixtures[row["sample"]]["expectsSpeech"] and row["status"] == "empty" for row in outcomes),
        } for strategy in ("whole", "segmented", "hybrid")],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    summary = summarize(json.loads(args.report.read_text()))
    text = json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
