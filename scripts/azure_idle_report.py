#!/usr/bin/env python3
import argparse
import csv
import io
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone


# --- helpers ---------------------------------------------------------------

_az_path_checked = False


def ensure_az_on_path():
    global _az_path_checked
    if _az_path_checked:
        return

    # Apple Silicon Homebrew default path
    if not shutil.which("az") and os.path.exists("/opt/homebrew/bin/az"):
        os.environ["PATH"] = "/opt/homebrew/bin:" + os.environ.get("PATH", "")

    if not shutil.which("az"):
        raise RuntimeError("Azure CLI (az) not found in PATH. Install via: brew install azure-cli")

    _az_path_checked = True


def run(cmd, expect_json=False, timeout=120):
    ensure_az_on_path()
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Command timed out after {timeout}s:\n  {' '.join(cmd)}")

    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()

    if p.returncode != 0:
        raise RuntimeError(f"Command failed:\n  {' '.join(cmd)}\n\n{err}")

    if expect_json:
        return json.loads(out) if out else []
    return out


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


def prompt_tenant_id():
    tid = input("Azure Tenant ID (Directory ID): ").strip()
    if not tid:
        raise SystemExit("Tenant ID is required.")
    return tid


def az_login(tenant_id, device_code=False):
    print(f"\nLogging in to tenant: {tenant_id}\n")
    cmd = ["az", "login", "--tenant", tenant_id, "--output", "none"]
    if device_code:
        cmd.append("--use-device-code")
    run(cmd, expect_json=False)


def list_subscriptions():
    subs = run(["az", "account", "list", "--all", "-o", "json"], expect_json=True)
    subs = [s for s in subs if (s.get("state") or "").lower() == "enabled"]
    return subs


def set_subscription(sub_id):
    run(["az", "account", "set", "--subscription", sub_id], expect_json=False)


CURRENCY_SYMBOLS = {
    "GBP": "£",
    "USD": "$",
    "EUR": "€",
    "CAD": "CA$",
    "AUD": "A$",
    "JPY": "¥",
    "CHF": "CHF ",
    "SEK": "kr ",
    "NOK": "kr ",
    "DKK": "kr ",
    "INR": "₹",
    "BRL": "R$",
    "ZAR": "R ",
}


def money_fmt(v, currency="GBP"):
    if v is None:
        return ""
    symbol = CURRENCY_SYMBOLS.get(currency, f"{currency} ")
    return f"{symbol}{v:.2f}"


def sub_matches(sub, names_or_ids):
    """Check if a subscription matches by name OR id."""
    sub_name = (sub.get("name") or "").strip()
    sub_id = (sub.get("id") or "").strip()
    return sub_name in names_or_ids or sub_id in names_or_ids


# --- AKS heuristics --------------------------------------------------------

_AKS_RG_PATTERN = re.compile(
    r"(^MC_)"            # AKS-managed RGs start with MC_
    r"|([_\-]aks[_\-])"  # aks delimited by - or _ (avoids matching 'flasks', 'tasks' etc.)
    r"|(^aks[_\-])"      # starts with aks- or aks_
    r"|([_\-]aks$)"      # ends with -aks or _aks
    , re.IGNORECASE
)


def is_aks_related(name, resource_group):
    n = (name or "").lower()
    rg = resource_group or ""

    if _AKS_RG_PATTERN.search(rg):
        return True

    # PVC disks
    if n.startswith("pvc-"):
        return True

    # kube / private endpoint-ish NICs
    if "kube" in n or "kube-apiserver.nic" in n or "-pe-" in n:
        return True

    return False


# --- inventory (CLI) -------------------------------------------------------

def get_orphaned_disks():
    """
    Finds disks that are genuinely unattached via 'az resource list'.
    Checks managedBy == null (original, reliable filter) and also
    diskState == 'Unattached' where available, to catch disks whose
    parent VM was deleted.
    """
    # managedBy == null — the proven filter
    by_managed = run([
        "az", "resource", "list",
        "--resource-type", "Microsoft.Compute/disks",
        "--query",
        "[?properties.managedBy==null].{id:id, name:name, resourceGroup:resourceGroup, location:location, sizeGb:properties.diskSizeGB, sku:sku.name}",
        "-o", "json"
    ], expect_json=True)

    # diskState == 'Unattached' — catches disks with a stale managedBy
    by_state = run([
        "az", "resource", "list",
        "--resource-type", "Microsoft.Compute/disks",
        "--query",
        "[?properties.diskState=='Unattached'].{id:id, name:name, resourceGroup:resourceGroup, location:location, sizeGb:properties.diskSizeGB, sku:sku.name}",
        "-o", "json"
    ], expect_json=True)

    # merge, deduplicate by resource id
    seen = set()
    result = []
    for d in by_managed + by_state:
        rid = (d.get("id") or "").lower()
        if rid and rid not in seen:
            seen.add(rid)
            result.append(d)
    return result


def get_unattached_public_ips():
    return run([
        "az", "network", "public-ip", "list",
        "--query", "[?ipConfiguration==null].{id:id, name:name, resourceGroup:resourceGroup, location:location, sku:sku.name, ip:ipAddress}",
        "-o", "json"
    ], expect_json=True)


def get_unattached_nics():
    return run([
        "az", "network", "nic", "list",
        "--query", "[?virtualMachine==null].{id:id, name:name, resourceGroup:resourceGroup, location:location}",
        "-o", "json"
    ], expect_json=True)


def get_stopped_not_deallocated_vms():
    # Deallocated is what stops compute billing. We only flag 'stopped' (not deallocated).
    vms = run([
        "az", "vm", "list", "-d",
        "--query", "[].{id:id, name:name, resourceGroup:resourceGroup, location:location, powerState:powerState}",
        "-o", "json"
    ], expect_json=True)

    likely = []
    for v in vms:
        ps = (v.get("powerState") or "").lower()
        if "stopped" in ps and "deallocated" not in ps:
            likely.append(v)
    return likely


def get_snapshots_older_than_days(days):
    snaps = run([
        "az", "snapshot", "list",
        "--query", "[].{id:id, name:name, resourceGroup:resourceGroup, location:location, timeCreated:timeCreated, sizeGb:diskSizeGB}",
        "-o", "json"
    ], expect_json=True)

    cutoff = datetime.now(timezone.utc).timestamp() - (days * 86400)
    out = []
    for s in snaps:
        tc = s.get("timeCreated")
        if not tc:
            continue
        try:
            tcn = tc.replace("Z", "+00:00")
            dt = datetime.fromisoformat(tcn)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            if dt.timestamp() <= cutoff:
                s["ageDays"] = int((datetime.now(timezone.utc) - dt).days)
                out.append(s)
        except Exception:
            continue
    return out


# --- cost management (actual £) -------------------------------------------

def get_cost_map_last30d_by_resource_id(subscription_id):
    """
    Uses Cost Management Query API via 'az rest' and groups by ResourceId.
    Handles pagination via nextLink for large subscriptions.
    """
    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/providers/Microsoft.CostManagement/query?api-version=2025-03-01"
    )

    body = {
        "type": "Usage",
        "timeframe": "Last30Days",
        "dataset": {
            "granularity": "None",
            "aggregation": {
                "totalCost": {"name": "PreTaxCost", "function": "Sum"}
            },
            "grouping": [
                {"type": "Dimension", "name": "ResourceId"}
            ]
        }
    }

    # First request
    resp = run(
        ["az", "rest", "--method", "post", "--uri", url, "--body", json.dumps(body), "-o", "json"],
        expect_json=True
    )

    all_rows = []
    cols = []

    def extract_from_response(r):
        nonlocal cols
        props = r.get("properties", {}) if isinstance(r, dict) else {}
        if not cols:
            cols = props.get("columns", [])
        rows = props.get("rows", [])
        all_rows.extend(rows)
        return props.get("nextLink")

    next_link = extract_from_response(resp)

    # Paginate
    while next_link:
        try:
            resp = run(
                ["az", "rest", "--method", "post", "--uri", next_link, "--body", json.dumps(body), "-o", "json"],
                expect_json=True
            )
            next_link = extract_from_response(resp)
        except Exception:
            break  # stop pagination on error, use what we have

    # Find column indices
    idx_cost = None
    idx_rid = None
    idx_currency = None

    for i, c in enumerate(cols):
        name = (c.get("name") or "").lower()
        if name == "pretaxcost":
            idx_cost = i
        elif name == "resourceid":
            idx_rid = i
        elif name == "currency":
            idx_currency = i

    if idx_cost is None or idx_rid is None:
        return {}, None  # can't map

    cost_map = {}
    currency = None

    for r in all_rows:
        rid = r[idx_rid]
        cost = r[idx_cost]
        if idx_currency is not None:
            currency = r[idx_currency]
        if not rid:
            continue
        cost_map[str(rid).lower()] = float(cost or 0.0)

    return cost_map, currency


# --- structured output -----------------------------------------------------

def build_findings(
    subscription_name, subscription_id,
    immediate_lines, review_lines, snapshot_lines,
    cost_immediate, cost_review, currency,
    no_cost
):
    """Build a list of dicts for structured (JSON/CSV) output."""
    findings = []

    for item in immediate_lines:
        entry = {
            "subscription": subscription_name,
            "subscriptionId": subscription_id,
            "bucket": "immediate",
            **item,
        }
        findings.append(entry)

    for item in review_lines:
        entry = {
            "subscription": subscription_name,
            "subscriptionId": subscription_id,
            "bucket": "aks_review",
            **item,
        }
        findings.append(entry)

    for item in snapshot_lines:
        entry = {
            "subscription": subscription_name,
            "subscriptionId": subscription_id,
            "bucket": "snapshot_review",
            **item,
        }
        findings.append(entry)

    return findings


def remediation_hint(resource_type, resource_id):
    """Return a suggested az CLI command for cleanup."""
    if not resource_id:
        return ""
    hints = {
        "disk":      f"az disk delete --ids {resource_id} --yes",
        "publicIp":  f"az network public-ip delete --ids {resource_id}",
        "nic":       f"az network nic delete --ids {resource_id}",
        "vm":        f"az vm deallocate --ids {resource_id}",
        "snapshot":  f"az snapshot delete --ids {resource_id}",
    }
    return hints.get(resource_type, "")


# --- main ------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Azure idle report with AKS review bucket + cost (last 30d)."
    )
    ap.add_argument("--tenant", help="Tenant ID (Directory ID). If omitted, will prompt.")
    ap.add_argument("--device-code", action="store_true", help="Use device code auth for az login.")

    ap.add_argument("--skip-subs", default="",
                     help="Comma-separated subscription names or IDs to skip.")
    ap.add_argument("--only-subs", default="",
                     help="Comma-separated subscription names or IDs to include (if set, only these are scanned).")

    ap.add_argument("--include-snapshots", action="store_true",
                     help="Include old snapshots as review-required.")
    ap.add_argument("--snapshot-days", type=int, default=180,
                     help="Snapshot age threshold (days). Default: 180.")

    ap.add_argument("--no-cost", action="store_true",
                     help="Disable Cost Management lookups (faster, no cost figures).")

    ap.add_argument("--output-format", choices=["text", "json", "csv"], default="text",
                     help="Output format. Default: text.")

    args = ap.parse_args()

    tenant_id = args.tenant or prompt_tenant_id()
    az_login(tenant_id, device_code=args.device_code)

    skip = set([s.strip() for s in args.skip_subs.split(",") if s.strip()])
    only = set([s.strip() for s in args.only_subs.split(",") if s.strip()])

    subs = list_subscriptions()
    if not subs:
        raise SystemExit("No enabled subscriptions found in this tenant.")

    is_structured = args.output_format in ("json", "csv")

    if not is_structured:
        print(f"\nReport generated: {utc_now_iso()}")
        print(f"Subscriptions in tenant: {len(subs)}")

    grand_counts = {
        "immediate_disks": 0,
        "immediate_pips": 0,
        "immediate_vms": 0,
        "aks_review_disks": 0,
        "aks_review_nics": 0,
        "immediate_nics": 0,
        "snapshots_old": 0,
    }

    grand_cost_immediate = 0.0
    grand_cost_review = 0.0
    grand_currency = None
    all_findings = []

    for s in subs:
        sub_id = s.get("id")
        sub_name = s.get("name") or sub_id or "Unknown"

        if only and not sub_matches(s, only):
            continue
        if sub_matches(s, skip):
            continue

        if not is_structured:
            print(f"\n=== {sub_name} ({sub_id}) ===")
        set_subscription(sub_id)

        # pull cost map (optional)
        cost_map = {}
        currency = None
        if not args.no_cost:
            try:
                cost_map, currency = get_cost_map_last30d_by_resource_id(sub_id)
                grand_currency = grand_currency or currency
            except Exception as e:
                if not is_structured:
                    print(f"(Cost data unavailable for this subscription: {str(e).splitlines()[-1]})")
                cost_map, currency = {}, None

        # inventory
        orphan_disks = get_orphaned_disks()
        public_ips = get_unattached_public_ips()
        nics = get_unattached_nics()
        vms_waste = get_stopped_not_deallocated_vms()

        snapshots_old = []
        if args.include_snapshots:
            snapshots_old = get_snapshots_older_than_days(args.snapshot_days)

        immediate_items = []  # list of dicts for structured output
        review_items = []
        snapshot_items = []

        immediate_lines = []  # text lines for console
        review_lines = []

        cost_immediate = 0.0
        cost_review = 0.0

        def get_cost(resource_id):
            if args.no_cost or not resource_id:
                return None
            return cost_map.get(str(resource_id).lower())

        def accumulate_cost(cost_val, bucket):
            nonlocal cost_immediate, cost_review
            if cost_val is None:
                return
            if bucket == "immediate":
                cost_immediate += cost_val
            else:
                cost_review += cost_val

        # Orphan disks => immediate or AKS review
        for d in orphan_disks:
            name = d.get("name")
            rg = d.get("resourceGroup")
            rid = d.get("id")
            cost_val = get_cost(rid)
            hint = remediation_hint("disk", rid)

            item = {
                "resourceType": "disk",
                "name": name,
                "resourceGroup": rg,
                "location": d.get("location"),
                "sizeGb": d.get("sizeGb"),
                "sku": d.get("sku"),
                "resourceId": rid,
                "costLast30d": cost_val,
                "currency": currency,
                "remediation": hint,
            }

            line = (
                f"Orphan disk: name={name}, resourceGroup={rg}, "
                f"location={d.get('location')}, sizeGb={d.get('sizeGb')}, sku={d.get('sku')}"
            )

            if is_aks_related(name, rg):
                accumulate_cost(cost_val, "review")
                review_items.append(item)
                if cost_val is not None:
                    cur = currency or "GBP"
                    line += f" last30d~{money_fmt(cost_val, cur)} est~{money_fmt(cost_val, cur)}/mo"
                review_lines.append(line)
                grand_counts["aks_review_disks"] += 1
            else:
                accumulate_cost(cost_val, "immediate")
                immediate_items.append(item)
                if cost_val is not None:
                    cur = currency or "GBP"
                    line += f" last30d~{money_fmt(cost_val, cur)} est~{money_fmt(cost_val, cur)}/mo"
                immediate_lines.append(line)
                grand_counts["immediate_disks"] += 1

        # Public IPs
        for p in public_ips:
            rid = p.get("id")
            cost_val = get_cost(rid)
            hint = remediation_hint("publicIp", rid)
            accumulate_cost(cost_val, "immediate")

            item = {
                "resourceType": "publicIp",
                "name": p.get("name"),
                "resourceGroup": p.get("resourceGroup"),
                "location": p.get("location"),
                "sku": p.get("sku"),
                "ip": p.get("ip"),
                "resourceId": rid,
                "costLast30d": cost_val,
                "currency": currency,
                "remediation": hint,
            }
            immediate_items.append(item)

            line = (
                f"Unattached Public IP: name={p.get('name')}, "
                f"resourceGroup={p.get('resourceGroup')}, location={p.get('location')}, "
                f"sku={p.get('sku')}, ip={p.get('ip')}"
            )
            if cost_val is not None:
                cur = currency or "GBP"
                line += f" last30d~{money_fmt(cost_val, cur)} est~{money_fmt(cost_val, cur)}/mo"
            immediate_lines.append(line)
            grand_counts["immediate_pips"] += 1

        # NICs
        for n in nics:
            name = n.get("name")
            rg = n.get("resourceGroup")
            rid = n.get("id")
            cost_val = get_cost(rid)
            hint = remediation_hint("nic", rid)

            item = {
                "resourceType": "nic",
                "name": name,
                "resourceGroup": rg,
                "location": n.get("location"),
                "resourceId": rid,
                "costLast30d": cost_val,
                "currency": currency,
                "remediation": hint,
            }

            line = f"Unattached NIC: name={name}, resourceGroup={rg}, location={n.get('location')}"

            if is_aks_related(name, rg):
                accumulate_cost(cost_val, "review")
                review_items.append(item)
                if cost_val is not None:
                    cur = currency or "GBP"
                    line += f" last30d~{money_fmt(cost_val, cur)} est~{money_fmt(cost_val, cur)}/mo"
                review_lines.append(line)
                grand_counts["aks_review_nics"] += 1
            else:
                immediate_items.append(item)
                line += " (housekeeping)"
                immediate_lines.append(line)
                grand_counts["immediate_nics"] += 1

        # Stopped (not deallocated) VMs
        for v in vms_waste:
            rid = v.get("id")
            cost_val = get_cost(rid)
            hint = remediation_hint("vm", rid)
            accumulate_cost(cost_val, "immediate")

            item = {
                "resourceType": "vm",
                "name": v.get("name"),
                "resourceGroup": v.get("resourceGroup"),
                "location": v.get("location"),
                "powerState": v.get("powerState"),
                "resourceId": rid,
                "costLast30d": cost_val,
                "currency": currency,
                "remediation": hint,
            }
            immediate_items.append(item)

            line = (
                f"VM not deallocated: name={v.get('name')}, "
                f"resourceGroup={v.get('resourceGroup')}, location={v.get('location')}, "
                f"powerState={v.get('powerState')}"
            )
            if cost_val is not None:
                cur = currency or "GBP"
                line += f" last30d~{money_fmt(cost_val, cur)} est~{money_fmt(cost_val, cur)}/mo"
            immediate_lines.append(line)
            grand_counts["immediate_vms"] += 1

        # Snapshots
        if args.include_snapshots:
            for sshot in snapshots_old:
                rid = sshot.get("id")
                hint = remediation_hint("snapshot", rid)
                snapshot_items.append({
                    "resourceType": "snapshot",
                    "name": sshot.get("name"),
                    "resourceGroup": sshot.get("resourceGroup"),
                    "location": sshot.get("location"),
                    "sizeGb": sshot.get("sizeGb"),
                    "ageDays": sshot.get("ageDays"),
                    "resourceId": rid,
                    "costLast30d": None,
                    "currency": currency,
                    "remediation": hint,
                })
                grand_counts["snapshots_old"] += 1

        # Structured output collection
        if is_structured:
            all_findings.extend(
                build_findings(
                    sub_name, sub_id,
                    immediate_items, review_items, snapshot_items,
                    cost_immediate, cost_review, currency, args.no_cost
                )
            )
        else:
            # Text output (original style)
            if immediate_lines:
                print("Immediate savings (safe-ish infra cleanup):")
                for l in immediate_lines:
                    print(f"  - {l}")
            else:
                print("Immediate savings: none")

            if review_lines:
                print("\nAKS review required (cluster-linked storage/network):")
                for l in review_lines:
                    print(f"  - {l}")
            else:
                print("\nAKS review required: none")

            if args.include_snapshots:
                if snapshots_old:
                    print(f"\nReview required (retention/policy): snapshots older than {args.snapshot_days} days:")
                    for sshot in sorted(snapshots_old, key=lambda x: x.get("ageDays", 0), reverse=True)[:20]:
                        hint = remediation_hint("snapshot", sshot.get("id"))
                        print(
                            f"  - Snapshot: name={sshot.get('name')}, rg={sshot.get('resourceGroup')}, "
                            f"loc={sshot.get('location')}, sizeGb={sshot.get('sizeGb')}, "
                            f"ageDays={sshot.get('ageDays')}"
                        )
                    if len(snapshots_old) > 20:
                        print(f"  - ... ({len(snapshots_old) - 20} more)")
                else:
                    print(f"\nReview required: no snapshots older than {args.snapshot_days} days")

            if not args.no_cost and currency:
                print(f"\nEstimated savings (Immediate, last30d): {money_fmt(cost_immediate, currency)}")
                print(f"Estimated savings (AKS review, last30d): {money_fmt(cost_review, currency)}")
                print(f"Estimated savings (Total, last30d): {money_fmt(cost_immediate + cost_review, currency)}")

        grand_cost_immediate += cost_immediate
        grand_cost_review += cost_review

    # --- final output ---

    if args.output_format == "json":
        output = {
            "generatedAt": utc_now_iso(),
            "tenantId": tenant_id,
            "summary": grand_counts,
            "findings": all_findings,
        }
        if not args.no_cost and grand_currency:
            output["costSummary"] = {
                "currency": grand_currency,
                "immediateLast30d": round(grand_cost_immediate, 2),
                "aksReviewLast30d": round(grand_cost_review, 2),
                "totalLast30d": round(grand_cost_immediate + grand_cost_review, 2),
            }
        print(json.dumps(output, indent=2, default=str))

    elif args.output_format == "csv":
        fieldnames = [
            "subscription", "subscriptionId", "bucket", "resourceType",
            "name", "resourceGroup", "location", "sizeGb", "sku", "ip",
            "powerState", "ageDays", "resourceId", "costLast30d", "currency",
            "remediation",
        ]
        buf = io.StringIO()
        writer = csv.DictWriter(buf, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for f in all_findings:
            writer.writerow(f)
        print(buf.getvalue(), end="")

    else:
        # Text summary
        print("\n==============================")
        print("TOTAL COUNTS (all scanned subscriptions):")
        print(f"  Orphaned managed disks (Immediate): {grand_counts['immediate_disks']}")
        print(f"  Unattached public IPs (Immediate): {grand_counts['immediate_pips']}")
        print(f"  Stopped VMs not deallocated (Immediate): {grand_counts['immediate_vms']}")
        print(f"  Unattached NICs (Immediate housekeeping): {grand_counts['immediate_nics']}")
        print(f"  AKS review disks: {grand_counts['aks_review_disks']}")
        print(f"  AKS review NICs: {grand_counts['aks_review_nics']}")
        if args.include_snapshots:
            print(f"  Old snapshots (> {args.snapshot_days}d): {grand_counts['snapshots_old']}")

        if not args.no_cost and grand_currency:
            print("\nTOTAL ESTIMATED SAVINGS (last30d):")
            print(f"  Immediate: {money_fmt(grand_cost_immediate, grand_currency)}")
            print(f"  AKS review: {money_fmt(grand_cost_review, grand_currency)}")
            print(f"  Overall: {money_fmt(grand_cost_immediate + grand_cost_review, grand_currency)}")

        print("==============================\n")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)