"""OrCAD 17.2 TriExport worker. No GUI automation or application injection.

Capture creates PostScript and a job manifest. This separate process invokes
Cadence's installed netlister, exports the chosen Allegro ZIP or PADS ASC,
selects PDF pages, and commits exactly three files as one new directory.
"""
from __future__ import annotations

import argparse
import csv
import fnmatch
import hashlib
import json
import locale
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import zipfile
from dataclasses import dataclass
import io

from pypdf import PdfReader, PdfWriter

VERSION = "1.0.0-rc9"
NETLIST_FORMATS = {"allegro-pst": "_allegro.zip", "pads-v3": ".asc"}
PADS_ATOM = re.compile(r"^[A-Za-z0-9_~!#$%+=|/.:;<>-]+$")
ALLEGRO_FILES = {
    "pstchip.dat": "LIBRARY_PARTS",
    "pstxprt.dat": "EXPANDEDPARTLIST",
    "pstxnet.dat": "EXPANDEDNETLIST",
}


class ExportError(Exception):
    pass


@dataclass(frozen=True)
class Token:
    value: str
    quoted: bool = False


def lex_pst(text: str) -> list[Token]:
    """Read PST strings, comments and punctuation without interpreting paths.

    Backslashes in PST C_PATH fields are literal. Doubled quotes are escaped
    quotes. Reject truncated input instead of producing partial connectivity.
    """
    result = []
    i = 0
    while i < len(text):
        c = text[i]
        if c.isspace() or c == "\ufeff":
            i += 1
        elif c == "{":
            end = text.find("}", i + 1)
            if end < 0:
                raise ExportError("Unterminated PST comment.")
            i = end + 1
        elif c in "'\"":
            quote, chars = c, []
            i += 1
            while i < len(text):
                if text[i] == quote:
                    if i + 1 < len(text) and text[i + 1] == quote:
                        chars.append(quote)
                        i += 2
                        continue
                    i += 1
                    break
                chars.append(text[i])
                i += 1
            else:
                raise ExportError("Unterminated PST string.")
            result.append(Token("".join(chars), True))
        elif c in "=,:;()":
            result.append(Token(c))
            i += 1
        else:
            start = i
            while i < len(text) and not text[i].isspace() and text[i] not in "{}'\"=,:;()":
                i += 1
            if start == i:
                raise ExportError(f"Unsupported PST character: {text[i]!r}")
            result.append(Token(text[start:i]))
    return result


def keyword(token: Token, name: str) -> bool:
    return not token.quoted and token.value.casefold() == name.casefold()


def read_text(path: Path, encoding: str | None = None) -> str:
    data = path.read_bytes()
    for enc in dict.fromkeys([encoding, "utf-8-sig", locale.getpreferredencoding(False), "gb18030"]):
        if not enc:
            continue
        try:
            return data.decode(enc)
        except (UnicodeError, LookupError):
            continue
    raise ExportError(f"Could not decode {path.name}. Check the system locale and schematic text.")


def load_pst(path: Path, file_type: str) -> list[Token]:
    if not path.is_file() or path.stat().st_size == 0:
        raise ExportError(f"Cadence did not produce {path.name}. See the diagnostic log.")
    tokens = lex_pst(read_text(path))
    if (len(tokens) < 5 or not keyword(tokens[0], "FILE_TYPE") or
            tokens[1].value != "=" or tokens[2].value != file_type):
        raise ExportError(f"Incorrect FILE_TYPE in {path.name}.")
    if not keyword(tokens[-1], "END."):
        raise ExportError(f"Incomplete {path.name}: missing END.")
    return tokens


def assignments(tokens: list[Token]) -> dict[str, list[str]]:
    props: dict[str, list[str]] = {}
    for i in range(len(tokens) - 2):
        if tokens[i + 1].value == "=" and not tokens[i + 1].quoted:
            props.setdefault(tokens[i].value.upper(), []).append(tokens[i + 2].value)
    return props


def parse_primitives(tokens: list[Token]) -> dict:
    primitives = {}
    i = 0
    while i < len(tokens):
        if keyword(tokens[i], "primitive"):
            if i + 1 >= len(tokens) or not tokens[i + 1].quoted:
                raise ExportError("The primitive record has no component name.")
            name = tokens[i + 1].value
            if name in primitives:
                raise ExportError(f"Duplicate primitive definition: {name}")
            end = next((j for j in range(i + 2, len(tokens)) if keyword(tokens[j], "end_primitive")), None)
            if end is None:
                raise ExportError(f"Unterminated primitive definition: {name}")
            body = next((j for j in range(i + 2, end) if keyword(tokens[j], "body")), None)
            body_end = next((j for j in range(body + 1, end) if keyword(tokens[j], "end_body")), None) if body else None
            if body is None or body_end is None:
                raise ExportError(f"Primitive definition has no body: {name}")
            primitives[name] = assignments(tokens[body + 1:body_end])
            i = end
        i += 1
    if not primitives:
        raise ExportError("No physical component definitions in the netlist.")
    return primitives


def parse_parts(tokens: list[Token]) -> dict:
    parts = {}
    for i, tok in enumerate(tokens):
        if keyword(tok, "PART_NAME"):
            if i + 1 < len(tokens) and tokens[i + 1].value == "=":
                continue  # An attribute, not a physical part record.
            if i + 2 >= len(tokens):
                raise ExportError("Incomplete PART_NAME record.")
            if not tokens[i + 2].quoted:
                raise ExportError("PART_NAME record has no referenced primitive.")
            ref, primitive = tokens[i + 1].value, tokens[i + 2].value
            if ref in parts:
                raise ExportError(f"Duplicate reference: {ref}")
            parts[ref] = primitive
    if not parts:
        raise ExportError("No PCB components to export.")
    return parts


def parse_nets(tokens: list[Token], parts: dict) -> dict[str, set[tuple[str, str]]]:
    nets: dict[str, set[tuple[str, str]]] = {}
    owners: dict[tuple[str, str], str] = {}
    name = None
    for i, tok in enumerate(tokens):
        if keyword(tok, "NET_NAME"):
            if i + 1 >= len(tokens) or not tokens[i + 1].quoted:
                raise ExportError("NET_NAME record has no net name.")
            name = tokens[i + 1].value
            if name in nets:
                raise ExportError(f"Duplicate net name: {name}")
            nets[name] = set()
        elif keyword(tok, "NODE_NAME"):
            if name is None or i + 2 >= len(tokens):
                raise ExportError("Incomplete NODE_NAME record.")
            ref, pin = tokens[i + 1].value, tokens[i + 2].value
            if ref not in parts:
                raise ExportError(f"Net {name} references unknown component {ref}.")
            if not ref or not pin:
                raise ExportError("NODE_NAME record has an empty reference or pin.")
            node = (ref, pin)
            if node in owners and owners[node] != name:
                raise ExportError(f"Pin {node} appears on both {owners[node]} and {name}.")
            owners[node] = name
            nets[name].add(node)
    return nets


def natural(value: str):
    return [(1, int(p)) if p.isdigit() else (0, p.casefold()) for p in re.split(r"(\d+)", value)]


def package_allegro(pst_dir: Path, output: Path, log: Path | None = None) -> dict[str, str]:
    """Package exactly the three Cadence-native files without rewriting bytes.

    Read-only structural checks also supply the physical reference/footprint
    map for BOM grouping. Native power, hierarchy, properties and encoding
    remain Cadence's responsibility; no PADS naming rules or power expansion.
    """
    tokens = {name: load_pst(pst_dir / name, kind) for name, kind in ALLEGRO_FILES.items()}
    primitives = parse_primitives(tokens["pstchip.dat"])
    parts = parse_parts(tokens["pstxprt.dat"])
    parse_nets(tokens["pstxnet.dat"], parts)
    footprints = {}
    for ref, primitive in parts.items():
        if primitive not in primitives:
            raise ExportError(f"{ref} references missing primitive {primitive}.")
        footprint = primitives[primitive].get("JEDEC_TYPE", [""])[-1]
        if not footprint.strip():
            raise ExportError(f"Missing PCB Footprint for {ref}. Fix the schematic.")
        footprints[ref] = footprint
    source_bytes = {name: (pst_dir / name).read_bytes() for name in ALLEGRO_FILES}
    # Fixed timestamps give deterministic archives for identical native files.
    with zipfile.ZipFile(output, "w") as archive:
        for name, data in source_bytes.items():
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    with zipfile.ZipFile(output) as archive:
        if archive.namelist() != list(ALLEGRO_FILES) or archive.testzip() is not None:
            raise ExportError("Allegro netlist ZIP verification failed.")
        if any(archive.read(name) != data for name, data in source_bytes.items()):
            raise ExportError("Allegro netlist bytes changed during packaging.")
    if log is not None:
        with log.open("a", encoding="utf-8") as stream:
            for name, data in source_bytes.items():
                stream.write(f"Allegro native SHA256 {name}: {hashlib.sha256(data).hexdigest()}\n")
    return footprints


def atom(value: str, kind: str, limit: int | None = None):
    if not value or not PADS_ATOM.fullmatch(value) or (limit and len(value) > limit):
        cap = f", maximum {limit} characters" if limit else ""
        raise ExportError(f"Invalid PADS 2000/V3 {kind}{cap}: {value!r}. Fix the schematic; names are never silently changed.")


def add_power_pins(nets: dict, parts: dict, primitives: dict):
    """PST stores hidden package power pins in the primitive body.

    Explicit flattened nodes take precedence over the package default. Power
    groups requiring an unresolved remap fail closed rather than guessing.
    """
    owners = {node: name for name, nodes in nets.items() for node in nodes}
    explicit = set(owners)
    for ref, prim in parts.items():
        if prim not in primitives:
            raise ExportError(f"{ref} references missing primitive {prim}.")
        props = primitives[prim]
        for expression in props.get("POWER_PINS", []):
            if not (expression.startswith("(") and expression.endswith(")")):
                raise ExportError(f"Unsupported power pin syntax: {ref}: {expression}")
            # Standard PST: '(VCC:14)' or '(VCC:14,28)'.
            groups = re.split(r"\)\s*\(", expression[1:-1])
            for group in groups:
                if group.count(":") != 1:
                    raise ExportError(f"Check the power pin mapping: {ref}: {expression}")
                net, pins = group.split(":", 1)
                net = net.strip()
                atom(net, "power net name", 47)
                for pin in pins.split(","):
                    pin = pin.strip()
                    atom(pin, f"power pin of {ref}")
                    node = (ref, pin)
                    if node in explicit:
                        continue
                    if node in owners and owners[node] != net:
                        raise ExportError(f"Conflicting implicit power nets for {node}.")
                    if any(props.get("POWER_GROUP", [])):
                        raise ExportError(f"{ref} has POWER_GROUP and unexpanded {node}; power connectivity cannot be inferred.")
                    nets.setdefault(net, set()).add(node)
                    owners[node] = net


def convert_pads(pst_dir: Path, output: Path) -> dict[str, str]:
    primitives = parse_primitives(load_pst(pst_dir / "pstchip.dat", "LIBRARY_PARTS"))
    part_tokens = load_pst(pst_dir / "pstxprt.dat", "EXPANDEDPARTLIST")
    if any(keyword(t, "POWER_GROUP") for t in part_tokens):
        raise ExportError("Parts contain POWER_GROUP remapping, which this version cannot infer.")
    parts = parse_parts(part_tokens)
    nets = parse_nets(load_pst(pst_dir / "pstxnet.dat", "EXPANDEDNETLIST"), parts)
    # Native tuple nodes remain unchanged in the Allegro path. Validate PADS
    # identifiers before formatting its REF.PIN representation.
    for nodes in nets.values():
        for ref, pin in nodes:
            atom(pin, f"pin number of {ref}")
    add_power_pins(nets, parts, primitives)
    footprints = {}
    case_refs = set()
    for ref, primitive in parts.items():
        atom(ref, "Reference", 16)
        if ref.casefold() in case_refs:
            raise ExportError(f"References differ only in case and conflict in PADS: {ref}")
        case_refs.add(ref.casefold())
        footprint = primitives[primitive].get("JEDEC_TYPE", [""])[-1]
        atom(footprint, f"PCB Footprint for {ref}")
        footprints[ref] = footprint
    seen_nets = set()
    lines = ["!PADS-POWERPCB-V3.0-MILS!", "*PART*"]
    lines += [f"{ref} {footprints[ref]}" for ref in sorted(parts, key=natural)]
    lines.append("*NET*")
    for net in sorted(nets, key=natural):
        atom(net, "net name", 47)
        if net.casefold() in seen_nets:
            raise ExportError(f"Net names differ only in case and conflict in PADS: {net}")
        seen_nets.add(net.casefold())
        nodes = sorted((ref + "." + pin for ref, pin in nets[net]), key=natural)
        if not nodes:
            continue
        lines.append("*SIGNAL* " + net)
        for start in range(0, len(nodes), 5):
            lines.append(" ".join(nodes[start:start + 5]))
    lines.append("*END*")
    output.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\r\n")
    return footprints


def csv_safe(value: str) -> str:
    # Preserve values as text when a spreadsheet would treat them as formulas.
    return "'" + value if value.lstrip().startswith(("=", "+", "-", "@")) else value


BOM_FIELDS = {"ref", "value", "footprint", "part_number", "manufacturer", "description", "dnp", "color", "property"}
BOM_OPS = {"equals", "not_equals", "contains", "not_contains", "glob", "is_empty", "not_empty"}


def validate_bom_filter(config=None) -> dict:
    if config is None:
        return {"enabled": False, "include_match": "any", "rules": []}
    if not isinstance(config, dict) or type(config.get("enabled")) is not bool:
        raise ExportError("Invalid BOM filter settings. Open BOM Filters and save the rules again.")
    if config.get("include_match") not in ("any", "all"):
        raise ExportError("Invalid BOM include match mode.")
    rules = config.get("rules")
    if not isinstance(rules, list) or len(rules) > 100:
        raise ExportError("BOM filters support up to 100 rules.")
    for rule in rules:
        if not isinstance(rule, dict) or not all(isinstance(rule.get(k), str) for k in ("action", "field", "op", "value", "property")):
            raise ExportError("Invalid BOM filter rule.")
        if rule["action"] not in ("include", "exclude") or rule["field"] not in BOM_FIELDS or rule["op"] not in BOM_OPS:
            raise ExportError("Unsupported BOM filter action, field or operator.")
        if rule["field"] == "property" and not rule["property"].strip():
            raise ExportError("Enter the custom property name for the BOM filter.")
        if rule["op"] not in ("is_empty", "not_empty") and not rule["value"].strip():
            raise ExportError("Enter a BOM filter value, or choose is_empty / not_empty.")
        if rule["field"] == "color" and (rule["op"] not in ("equals", "not_equals") or not re.fullmatch(r"[0-9]+", rule["value"])):
            raise ExportError("Part color requires equals / not_equals and a numeric Capture color ID.")
        if any(len(rule[k]) > 1024 for k in ("property", "value")):
            raise ExportError("BOM filter names and values must be at most 1024 characters.")
    return config


def bom_rule_matches(row: dict, footprint: str, rule: dict) -> bool:
    field = rule["field"]
    if field == "footprint":
        value = footprint
    elif field == "property":
        props = row.get("filter_values", {})
        if not isinstance(props, dict) or rule["property"] not in props:
            raise ExportError(f"BOM filter property was not captured for {row['ref']}. Restart Capture and export again.")
        value = props[rule["property"]]
    elif field == "color":
        if not re.fullmatch(r"[0-9]+", str(row.get("color", ""))):
            raise ExportError(f"Could not read the part color for {row['ref']}. No filtered BOM was committed.")
        value = str(int(row["color"]))
    else:
        value = row.get(field, "")
    value, wanted = str(value).strip().casefold(), rule["value"].strip().casefold()
    if field == "color":
        wanted = str(int(wanted))
    op = rule["op"]
    if op == "equals":
        return value == wanted
    if op == "not_equals":
        return value != wanted
    if op == "contains":
        return wanted in value
    if op == "not_contains":
        return wanted not in value
    if op == "glob":
        return fnmatch.fnmatchcase(value, wanted)
    if op == "is_empty":
        return not value
    return bool(value)


def write_bom(rows: list[dict], footprints: dict, output: Path, config=None, *, audit=None) -> int:
    config = validate_bom_filter(config)
    physical = {}
    units = {}
    for row in rows:
        ref = row["ref"]
        if ref not in footprints:
            continue  # Hierarchical blocks and simulation-only objects.
        values = tuple(str(row.get(k, "")) for k in ("value", "part_number", "manufacturer", "description", "dnp"))
        if ref in physical and physical[ref] != values:
            raise ExportError(f"Inconsistent BOM properties across units of {ref}.")
        physical[ref] = values
        units.setdefault(ref, []).append(row)
    missing = set(footprints) - set(physical)
    if missing:
        raise ExportError("BOM is missing netlist components: " + ", ".join(sorted(missing, key=natural)[:20]))
    # Validate full-design coverage before intentional filtering. A missing
    # occurrence must not be mistaken for a component excluded by a rule.
    excluded = []
    if config["enabled"]:
        for ref, occurrences in units.items():
            includes, excludes = [], []
            for rule in config["rules"]:
                # Evaluate every unit to detect unreadable color/property data.
                matches = [bom_rule_matches(row, footprints[ref], rule) for row in occurrences]
                (includes if rule["action"] == "include" else excludes).append(any(matches))
            keep = not includes or (all(includes) if config["include_match"] == "all" else any(includes))
            if not keep or any(excludes):
                excluded.append(ref)
        for ref in excluded:
            del physical[ref]
    if audit is not None:
        audit.update({"total": len(footprints), "included": len(physical), "excluded": len(excluded),
                      "excluded_refs": sorted(excluded, key=natural)})
    groups = {}
    for ref, values in physical.items():
        key = (values[0], footprints[ref], *values[1:])
        groups.setdefault(key, []).append(ref)
    with output.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["Item", "Reference", "Quantity", "Value", "PCB Footprint", "Part Number", "Manufacturer", "Description", "DNP / Assembly note"])
        ordered = sorted(groups.items(), key=lambda entry: natural(min(entry[1], key=natural)))
        for index, (key, refs) in enumerate(ordered, 1):
            writer.writerow([index, csv_safe(", ".join(sorted(refs, key=natural))), len(refs), *map(csv_safe, key)])
    return len(physical)


def run_tool(argv: list[str], log: Path, *, cwd: Path, env=None, timeout=180):
    with log.open("ab") as stream:
        stream.write(("\nCOMMAND: " + repr(argv) + "\n").encode("utf-8"))
        stream.flush()
        try:
            result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=stream, stderr=stream,
                                    cwd=cwd, env=env, timeout=timeout, check=False,
                                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except subprocess.TimeoutExpired as exc:
            raise ExportError(f"{Path(argv[0]).name} exceeded {timeout} seconds. Export stopped.") from exc
        if result.returncode:
            raise ExportError(f"{Path(argv[0]).name} failed ({result.returncode}). See the diagnostic log.")


def file_hash(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def snapshot_design(design: Path, expected_hash: str, stage: Path) -> Path:
    """Give pstswp a private writable copy, never the user's open DSN.

    Cadence's packaging pass can save metadata back into its -d input even on
    a successful run. Hash both the copy and the source before invoking it so
    PDF/BOM and connectivity still originate from the same saved revision.
    """
    if file_hash(design) != expected_hash:
        raise ExportError("The design file changed during preparation. Export again.")
    directory = stage / "design-snapshot"
    directory.mkdir()
    snapshot = directory / design.name
    # copyfile creates an independent writable file, without inheriting the
    # source's read-only attributes or introducing a hardlink to the source.
    shutil.copyfile(design, snapshot)
    if file_hash(snapshot) != expected_hash or file_hash(design) != expected_hash:
        raise ExportError("The design changed while making the export snapshot. Export again.")
    return snapshot


def native_netlist(job: dict, stage: Path, log: Path) -> Path:
    root = Path(job["cadence_root"])
    exe = root / "tools/bin/pstswp.exe"
    cfg = root / "tools/capture/allegro.cfg"
    design = Path(job["design"])
    if not exe.is_file() or not cfg.is_file():
        raise ExportError("Could not find pstswp.exe / allegro.cfg in the 17.2 installation.")
    if not design.is_file() or design.suffix.casefold() != ".dsn":
        raise ExportError("Save the active design as a .DSN file first.")
    snapshot = snapshot_design(design, job["design_hash"], stage)
    with log.open("a", encoding="utf-8") as stream:
        stream.write(f"\nSource SHA256 before netlisting: {job['design_hash']}\n"
                     f"Netlisting private DSN snapshot: {snapshot}\n")
    out = stage / "pst"
    out.mkdir()
    env = os.environ.copy()
    env["CDSROOT"] = str(root)
    env["PATH"] = str(root / "tools/bin") + os.pathsep + env.get("PATH", "")
    argv = [str(exe), "-pst", "-d", str(snapshot), "-n", str(out), "-c", str(cfg),
            "-v", "3", "-l", "31", "-j", "PCB Footprint", "-hpath", "HPathForCollision"]
    run_tool(argv, log, cwd=stage, env=env, timeout=300)
    source_hash = file_hash(design)
    with log.open("a", encoding="utf-8") as stream:
        stream.write(f"\nSnapshot SHA256 after netlisting: {file_hash(snapshot)}\n"
                     f"Source SHA256 after netlisting: {source_hash}\n")
    if source_hash != job["design_hash"]:
        raise ExportError("The source DSN changed during netlisting. No results committed.")
    # Some Cadence builds return zero despite reporting a netlisting error.
    for report in [log, *out.glob("*.log"), *out.glob("*.err")]:
        if re.search(r"(?im)^\s*(?:#\d+\s+)?(?:ERROR|FATAL)\s*\(", read_text(report)):
            raise ExportError("Cadence reported a netlisting error. See the diagnostic log and correct the schematic.")
    return out


def page_key(page: dict) -> tuple[str, str]:
    return str(page["schematic"]), str(page["name"])


def choose_page_indices(printed: list[dict], selected: list[dict], page_count: int) -> list[int]:
    if not selected:
        raise ExportError("Select at least one schematic page.")
    keys = [page_key(p) for p in printed]
    if len(keys) != page_count or len(set(keys)) != len(keys):
        raise ExportError("Print callback pages do not match the PDF. Export stopped to prevent incorrect pages.")
    wanted = [page_key(p) for p in selected]
    if len(set(wanted)) != len(wanted) or not set(wanted).issubset(keys):
        raise ExportError("Some selected pages are missing from the print output. Refresh the page list.")
    # UI order is also the requested PDF order, independent of native print order.
    return [keys.index(key) for key in wanted]


def make_pdf(job: dict, stage: Path, output: Path, log: Path):
    gs = Path(job["ghostscript"])
    if not gs.is_file() or gs.name.casefold() not in {"gswin64c.exe", "gswin32c.exe", "gs.exe", "gs"}:
        raise ExportError("Select Ghostscript gswin64c.exe / gswin32c.exe, not its installer.")
    ps = Path(job["postscript"])
    # Cadence's PostScript rendering callback records the actual print order.
    # Verify DSC page count as well as parsed PDF count before selecting pages.
    ps_bytes = ps.read_bytes()
    dsc_count = len(re.findall(rb"(?m)^%%Page:\s", ps_bytes))
    if dsc_count != len(job["printed_pages"]) or dsc_count == 0:
        raise ExportError("PostScript page count does not match Capture callbacks. Cannot safely select PDF pages.")
    full = stage / "all-pages.pdf"
    run_tool([str(gs), "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite",
              "-dCompatibilityLevel=1.4", "-sOutputFile=" + str(full), str(ps)], log, cwd=stage)
    with PdfReader(full, strict=True) as reader:
        indices = choose_page_indices(job["printed_pages"], job["selected_pages"], len(reader.pages))
        writer = PdfWriter()
        for new_index, old_index in enumerate(indices):
            writer.add_page(reader.pages[old_index])
            name = job["selected_pages"][new_index]
            writer.add_outline_item(name["schematic"] + " / " + name["name"], new_index)
        writer.add_metadata({"/Title": Path(job["design"]).stem, "/Creator": "OrCAD Capture 17.2 TriExport " + VERSION})
        with output.open("wb") as stream:
            writer.write(stream)
        writer.close()
    with PdfReader(output, strict=True) as check:
        if len(check.pages) != len(indices):
            raise ExportError("PDF page count verification failed.")
        for page in check.pages:
            if float(page.mediabox.width) <= 0 or float(page.mediabox.height) <= 0:
                raise ExportError("Invalid PDF page dimensions.")


def safe_basename(name: str) -> str:
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).rstrip(" .")[:80]
    if not value:
        value = "Design"
    if re.fullmatch(r"(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", value):
        value = "_" + value
    return value


def commit_three(files: list[Path], root: Path, stem: str, *, copier=shutil.copy2) -> Path:
    if len(files) != 3 or {p.suffix for p in files} not in ({".zip", ".pdf", ".csv"}, {".asc", ".pdf", ".csv"}):
        raise ExportError("Commit requires exactly three files: one netlist (.zip or .asc), .pdf and .csv.")
    if any(not p.is_file() or p.stat().st_size == 0 for p in files):
        raise ExportError("An output file is missing or empty.")
    if not root.is_dir():
        raise ExportError("The output root folder does not exist.")
    prefix = safe_basename(stem) + "_" + time.strftime("%Y%m%d_%H%M%S")
    pending = Path(tempfile.mkdtemp(prefix=".TriExport-", dir=root))
    try:
        for source in files:
            copier(source, pending / source.name)
        if len(list(pending.iterdir())) != 3:
            raise ExportError("Output file count verification failed.")
        for source in files:
            if file_hash(source) != file_hash(pending / source.name):
                raise ExportError("Output copy verification failed.")
        for attempt in range(1000):
            target = root / (prefix + (f"_{attempt}" if attempt else ""))
            if target.exists():
                continue
            try:
                # Windows rename is atomic on this same-volume directory and
                # refuses an existing target. Never overwrite a previous export.
                pending.rename(target)
                return target
            except FileExistsError:
                continue
        raise ExportError("Too many output folder name collisions. Choose another root folder.")
    finally:
        if pending.exists():
            shutil.rmtree(pending)


def status(job_dir: Path, text: str):
    temp = job_dir / "status.tmp"
    temp.write_text(text, encoding="utf-8")
    temp.replace(job_dir / "status.txt")


def execute_job(job: dict, job_dir: Path) -> dict:
    netlist_format = job.get("netlist_format")
    if netlist_format is None:
        raise ExportError("The open export panel is from an older version. Restart Capture to choose a netlist format.")
    if not isinstance(netlist_format, str) or netlist_format not in NETLIST_FORMATS:
        raise ExportError("Unsupported netlist format. Choose Allegro or PADS in the export panel.")
    bom_filter = validate_bom_filter(job.get("bom_filter"))
    log = job_dir / "diagnostic.log"
    with log.open("a", encoding="utf-8") as stream:
        stream.write(f"Requested netlist format: {netlist_format}\n")
    status(job_dir, "1/4 Running the Cadence netlister...")
    with tempfile.TemporaryDirectory(prefix="TriExport-") as scratch:
        stage = Path(scratch)
        pst = native_netlist(job, stage, log)
        stem = safe_basename(Path(job["design"]).stem)
        netlist = stage / (stem + NETLIST_FORMATS[netlist_format])
        pdf, bom = [stage / (stem + ext) for ext in (".pdf", ".csv")]
        if netlist_format == "allegro-pst":
            status(job_dir, "2/4 Packaging the Allegro netlist and BOM...")
            footprints = package_allegro(pst, netlist, log)
        else:
            status(job_dir, "2/4 Generating the PADS netlist and BOM...")
            footprints = convert_pads(pst, netlist)
        bom_audit = {}
        count = write_bom(job["bom_rows"], footprints, bom, bom_filter, audit=bom_audit)
        with log.open("a", encoding="utf-8") as stream:
            stream.write("BOM filter result: " + json.dumps(bom_audit, ensure_ascii=False) + "\n")
        status(job_dir, "3/4 Converting PDF and extracting selected pages...")
        make_pdf(job, stage, pdf, log)
        if file_hash(Path(job["design"])) != job["design_hash"]:
            raise ExportError("The design was saved as a new revision during export. Export again.")
        status(job_dir, "4/4 Verifying and committing three files...")
        output = commit_three([netlist, pdf, bom], Path(job["root"]), stem)
        return {"ok": True, "output": str(output), "pages": len(job["selected_pages"]), "parts": count,
                "netlist_parts": len(footprints), "bom_excluded": bom_audit["excluded"],
                "netlist_format": netlist_format,
                "files": [str(output / p.name) for p in (netlist, pdf, bom)]}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["run", "hash", "selftest"])
    parser.add_argument("path", nargs="?")
    parser.add_argument("--output", help="Explicit output file for hash mode")
    args = parser.parse_args(argv)
    if args.mode == "selftest":
        # Verify frozen PDF dependencies actually read/write a page, without
        # invoking any native CAD software or external converter.
        buffer = io.BytesIO()
        with PdfWriter() as writer:
            writer.add_blank_page(width=320, height=240)
            writer.add_outline_item("Test", 0)
            writer.write(buffer)
        buffer.seek(0)
        with PdfReader(buffer) as reader:
            if len(reader.pages) != 1 or int(reader.pages[0].mediabox.width) != 320:
                raise ExportError("PDF runtime self-test failed")
        if args.path:
            Path(args.path).write_text(json.dumps({"ok": True, "version": VERSION, "pdf": PdfReader.__module__, "pdf_roundtrip": True}), encoding="utf-8")
        return 0
    if args.mode == "hash":
        # Used synchronously before Capture rendering so later native output
        # must describe the exact same saved design revision.
        if not args.path or not args.output:
            parser.error("hash requires a source path and --output")
        Path(args.output).write_text(file_hash(Path(args.path)), encoding="ascii")
        return 0
    if not args.path:
        parser.error("run requires a job manifest")
    job_file = Path(args.path).resolve()
    job_dir = job_file.parent
    try:
        job = json.loads(job_file.read_text(encoding="utf-8-sig"))
        result = execute_job(job, job_dir)
    except Exception as exc:
        with (job_dir / "diagnostic.log").open("a", encoding="utf-8") as stream:
            stream.write(traceback.format_exc())
        result = {"ok": False, "error": str(exc), "log": str(job_dir / "diagnostic.log")}
    tmp = job_dir / "result.tmp"
    tmp.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    tmp.replace(job_dir / "result.json")
    status(job_dir, "Export complete." if result["ok"] else "Export failed. No results committed.")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
