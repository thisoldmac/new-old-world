#!/usr/bin/env python3
"""Parse a PEF (CFM Preferred Executable Format) container.

The Mac OS ROM on a New World Macintosh is a CHRP boot script wrapping a
PEF - so the Toolbox we are reverse-engineering is an ordinary CFM
container, with a loader section that names its imports and exports. That
export table is the Toolbox's own API surface with offsets attached, and
it is readable statically with no emulator running.

    pef.py <file> [--find NewGWorld] [--dump-code out.bin]
"""
import argparse, struct, sys

def u32(b, o): return struct.unpack_from(">I", b, o)[0]
def u16(b, o): return struct.unpack_from(">H", b, o)[0]

class PEF:
    def __init__(self, blob, base=0):
        self.blob = blob
        self.base = base
        tag1, tag2, arch = blob[base:base+4], blob[base+4:base+8], blob[base+8:base+12]
        if tag1 != b"Joy!" or tag2 != b"peff":
            raise SystemExit("not a PEF at 0x%x (%r%r)" % (base, tag1, tag2))
        self.arch = arch.decode("latin1")
        self.version = u32(blob, base+12)
        self.section_count = u16(blob, base+32)
        self.inst_count = u16(blob, base+34)
        self.sections = []
        off = base + 40
        for i in range(self.section_count):
            (name_off, default_addr, total_size, unpacked_size, packed_size,
             container_off, perms, align) = struct.unpack_from(
                ">iIIIIIBB", blob, off)
            self.sections.append({
                "i": i, "nameOff": name_off, "defaultAddr": default_addr,
                "totalSize": total_size, "unpackedSize": unpacked_size,
                "packedSize": packed_size, "containerOff": container_off,
                "kind": perms, "align": align,
            })
            off += 28

    KINDS = {0: "code", 1: "unpacked-data", 2: "pattern-data", 3: "constant",
             4: "loader", 5: "debug", 6: "exec-data", 7: "exception",
             8: "traceback"}

    def section_bytes(self, s):
        start = self.base + s["containerOff"]
        return self.blob[start:start + s["packedSize"]]

    def loader(self):
        for s in self.sections:
            if s["kind"] == 4:
                return s
        return None

    def exports(self):
        ldr = self.loader()
        if ldr is None:
            return [], []
        L = self.section_bytes(ldr)
        (main_sec, main_off, init_sec, init_off, term_sec, term_off,
         imported_lib_count, total_imported_syms, reloc_sec_count,
         reloc_inst_off, loader_strings_off, export_hash_off,
         export_hash_power, exported_sym_count) = struct.unpack_from(
            ">iIiIiIIIIIIIII", L, 0)
        strings = L[loader_strings_off:]

        def stringz(off):
            end = strings.find(b"\0", off)
            return strings[off:end].decode("mac-roman", "replace")

        # imported libraries, then the imported SYMBOL table that follows
        # them. Each library owns the contiguous run
        # [firstImportedSym, +importedSymCount) of that table, which is
        # what makes "which fragment does NewGWorld resolve against?"
        # answerable statically - the question plan 014's E0 asks.
        libs = []
        off = 56
        for i in range(imported_lib_count):
            (name_off, old_impl, curr_ver, imported_sym_count,
             first_imported_sym, options, _r) = struct.unpack_from(
                ">IIIIIBB", L, off)
            libs.append({"name": stringz(name_off),
                         "symbols": imported_sym_count,
                         "first": first_imported_sym})
            off += 24

        # One 4-byte entry per imported symbol: class in the top byte,
        # name offset in the low 24 bits (the export table's encoding).
        sym_table_off = off
        for lib in libs:
            names = []
            for j in range(lib["symbols"]):
                entry = u32(L, sym_table_off + (lib["first"] + j) * 4)
                names.append({"name": stringz(entry & 0xFFFFFF),
                              "class": (entry >> 24) & 0x0F})
            lib["imports"] = names

        # exports: hash table, then key table, then the symbol table
        hash_entries = 1 << export_hash_power
        key_off = export_hash_off + hash_entries * 4
        sym_off = key_off + exported_sym_count * 4
        out = []
        for i in range(exported_sym_count):
            classAndName, symValue, symSection = struct.unpack_from(
                ">IIh", L, sym_off + i * 10)
            cls = (classAndName >> 24) & 0xFF
            name_off = classAndName & 0xFFFFFF
            out.append({"name": stringz(name_off), "class": cls,
                        "value": symValue, "section": symSection})
        return libs, out

CLASSES = {0: "code", 1: "data", 2: "tvect", 3: "toc", 4: "glue"}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--at", type=lambda s: int(s, 0), default=None)
    ap.add_argument("--find", action="append", default=[])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--imports", action="append", default=[],
                    help="name (substring) to locate in the IMPORT table, "
                         "reporting which library it resolves against")
    ap.add_argument("--list-imports", action="store_true")
    ap.add_argument("--dump-code")
    a = ap.parse_args()

    blob = open(a.file, "rb").read()
    base = a.at if a.at is not None else blob.find(b"Joy!peff")
    if base < 0:
        raise SystemExit("no PEF container found")
    p = PEF(blob, base)
    print("PEF at 0x%x  arch=%s sections=%d" % (base, p.arch, p.section_count))
    for s in p.sections:
        print("  [%d] %-14s defaultAddr=0x%08x total=%-9d packed=%-9d off=0x%x"
              % (s["i"], PEF.KINDS.get(s["kind"], str(s["kind"])),
                 s["defaultAddr"], s["totalSize"], s["packedSize"],
                 s["containerOff"]))
    libs, exps = p.exports()
    print("imported libraries: %d" % len(libs))
    for l in libs:
        print("   %-28s %d symbols" % (l["name"], l["symbols"]))
    print("exported symbols: %d" % len(exps))
    if a.list:
        for e in exps:
            print("   %-40s %-6s sec=%-3d value=0x%08x"
                  % (e["name"], CLASSES.get(e["class"], e["class"]),
                     e["section"], e["value"]))
    if a.list_imports:
        for l in libs:
            print("-- %s (%d)" % (l["name"], l["symbols"]))
            for s in l.get("imports", []):
                print("     %-40s %s"
                      % (s["name"], CLASSES.get(s["class"], s["class"])))
    for needle in a.imports:
        print("-- import %r:" % needle)
        found = False
        for l in libs:
            for s in l.get("imports", []):
                if needle.lower() in s["name"].lower():
                    print("   %-40s <- %s  (%s)"
                          % (s["name"], l["name"],
                             CLASSES.get(s["class"], s["class"])))
                    found = True
        if not found:
            print("   (not imported)")
    for needle in a.find:
        hits = [e for e in exps if needle.lower() in e["name"].lower()]
        print("-- %r: %d hit(s)" % (needle, len(hits)))
        for e in hits[:60]:
            print("   %-40s %-6s sec=%-3d value=0x%08x"
                  % (e["name"], CLASSES.get(e["class"], e["class"]),
                     e["section"], e["value"]))
    if a.dump_code:
        for s in p.sections:
            if s["kind"] == 0:
                open(a.dump_code, "wb").write(p.section_bytes(s))
                print("code section %d -> %s (%d bytes, defaultAddr 0x%08x)"
                      % (s["i"], a.dump_code, s["packedSize"], s["defaultAddr"]))
                break

if __name__ == "__main__":
    main()
