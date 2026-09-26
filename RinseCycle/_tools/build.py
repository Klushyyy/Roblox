"""Builds RinseCycle.rbxlx and sourcemap.json from the script mirror.

A Python port of build.ps1 for Mac/Linux (same output). Folder layout mirrors
Studio, using Studio Script Sync file names:
  Name.server.luau  -> Script (RunContext Server)
  Name.local.luau   -> LocalScript
  Name.luau         -> ModuleScript
  any other directory -> Folder (directories starting with "_" are skipped)

Run:  python3 _tools/build.py
      add  --map-only [--map-out <path>]  to write only a sourcemap (used by the type checker)
"""

import argparse
import json
import os
import sys
import xml.dom.minidom

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SERVICE_NAMES = ["Workspace", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService",
                 "ServerStorage", "StarterPlayer", "StarterGui", "Lighting", "SoundService"]
SPECIAL_FOLDERS = {"StarterPlayerScripts": "StarterPlayerScripts",
                   "StarterCharacterScripts": "StarterCharacterScripts"}
# Extra properties written onto specific services in the place file.
SERVICE_PROPS = {"StarterPlayer": "", "Workspace": '<bool name="StreamingEnabled">false</bool>'}

ref = 0


def next_ref():
    global ref
    ref += 1
    return "RBX%08X" % ref


def escape_xml(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def escape_source(s):
    # Entity-escape rather than CDATA: Studio has rejected split CDATA sections,
    # and Luau can legitimately contain "]]>" (e.g. t[a[1]]>0).
    s = s.replace("\r\n", "\n").rstrip()
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def script_info(file_name):
    if file_name.endswith(".server.luau"):
        return "Script", file_name[:-12]
    if file_name.endswith(".local.luau"):
        return "LocalScript", file_name[:-11]
    if file_name.endswith(".client.luau"):
        raise SystemExit(f"{file_name} : use .local.luau for LocalScripts (.client.luau is a "
                         "RunContext=Client Script and runs twice in Starter containers)")
    if file_name.endswith(".luau"):
        return "ModuleScript", file_name[:-5]
    return None


def sorted_entries(path):
    # PowerShell's Sort-Object Name is case-insensitive.
    return sorted(os.listdir(path), key=str.lower)


def build_dir(path, class_name, rel_path, xml_out):
    name = os.path.basename(path)
    xml_out.append(f'<Item class="{class_name}" referent="{next_ref()}"><Properties>'
                   f'<string name="Name">{escape_xml(name)}</string>')
    xml_out.append(SERVICE_PROPS.get(class_name, ""))
    xml_out.append("</Properties>\n")
    node = {"name": name, "className": class_name, "children": []}

    entries = sorted_entries(path)
    for sub in entries:
        full = os.path.join(path, sub)
        if not os.path.isdir(full) or sub.startswith("_"):
            continue
        cls = SPECIAL_FOLDERS.get(sub, "Folder")
        node["children"].append(build_dir(full, cls, f"{rel_path}/{sub}", xml_out))
    for file_name in entries:
        full = os.path.join(path, file_name)
        if not os.path.isfile(full):
            continue
        info = script_info(file_name)
        if info is None:
            continue
        cls, script_name = info
        with open(full, encoding="utf-8-sig") as f:
            src = f.read()
        xml_out.append(f'<Item class="{cls}" referent="{next_ref()}"><Properties>'
                       f'<string name="Name">{escape_xml(script_name)}</string>')
        if cls == "Script":
            xml_out.append('<bool name="Disabled">false</bool><token name="RunContext">1</token>')
        if cls == "LocalScript":
            xml_out.append('<bool name="Disabled">false</bool>')
        xml_out.append(f'<ProtectedString name="Source">{escape_source(src)}</ProtectedString>'
                       '</Properties></Item>\n')
        node["children"].append({"name": script_name, "className": cls,
                                 "filePaths": [f"{rel_path}/{file_name}"]})
    xml_out.append("</Item>\n")
    return node


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--map-only", action="store_true")
    parser.add_argument("--map-out", default="")
    args = parser.parse_args()

    out_place = os.path.join(ROOT, "RinseCycle.rbxlx")
    out_map = args.map_out or os.path.join(ROOT, "_tools", "sourcemap.json")

    xml_out = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
               'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
               'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">\n']
    tree = {"name": "RinseCycle", "className": "DataModel", "children": []}
    for svc in SERVICE_NAMES:
        path = os.path.join(ROOT, svc)
        if not os.path.isdir(path):
            if svc in SERVICE_PROPS:
                xml_out.append(f'<Item class="{svc}" referent="{next_ref()}"><Properties>'
                               f'<string name="Name">{svc}</string>{SERVICE_PROPS[svc]}</Properties></Item>\n')
            continue
        tree["children"].append(build_dir(path, svc, svc, xml_out))
    xml_out.append("</roblox>\n")

    with open(out_map, "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(tree, ensure_ascii=False, separators=(",", ":")))
    if args.map_only:
        print(f"Built {out_map}")
        return

    data = "".join(xml_out)
    with open(out_place, "w", encoding="utf-8", newline="") as f:
        f.write(data)

    # Sanity check: the place file must be well-formed XML.
    doc = xml.dom.minidom.parseString(data.encode("utf-8"))
    scripts = sum(1 for item in doc.getElementsByTagName("Item")
                  if item.getAttribute("class") in ("Script", "LocalScript", "ModuleScript"))
    print(f"Built {out_place} ({scripts} scripts, {round(os.path.getsize(out_place) / 1024)} KB)")
    print(f"Built {out_map}")


if __name__ == "__main__":
    sys.exit(main())
