"""Is the Macintosh volume inside this disk image CLEANLY UNMOUNTED?

`qemu-img check` answers a different question — it validates the qcow2
container and knows nothing about the filesystem inside, so a volume the
Mac will greet with Disk First Aid passes it without complaint. That
mistake is why a dirty image was preserved as the Mirror oracle twice on
2026-08-06.

The Mac records the answer itself. HFS clears the "volume unmounted"
attribute bit while mounted and sets it on a clean unmount; a machine
that lost power leaves it clear, and that is exactly what the startup
check reads. So ask the volume.

  HFS+  volume header at +1024: signature 'H+'/'HX', attributes u32 at
        offset 4, bit 8 (0x100) = kHFSVolumeUnmountedBit.
  HFS   master directory block at +1024: signature 'BD', drAtrb u16 at
        offset 10, bit 8 = the same meaning.

Usage: volclean.py <image.qcow2 | image.raw> ...
Exit 0 only if EVERY image checked is cleanly unmounted.
"""
import struct, subprocess, sys, os, tempfile

UNMOUNTED = 0x100


def raw_of(path):
    """A raw view of the image. qcow2 is converted to a temp file."""
    with open(path, "rb") as f:
        if f.read(4) != b"QFI\xfb":
            return path, None
    tmp = tempfile.NamedTemporaryFile(suffix=".raw", delete=False,
                                      dir="/private/tmp")
    tmp.close()
    subprocess.run(["qemu-img", "convert", "-O", "raw", path, tmp.name],
                   check=True)
    return tmp.name, tmp.name


def partitions(raw):
    """Apple Partition Map entries, as (name, type, start_bytes)."""
    out = []
    with open(raw, "rb") as f:
        for blk in range(1, 64):          # map lives right after block 0
            f.seek(blk * 512)
            e = f.read(512)
            if len(e) < 512 or e[:2] != b"PM":
                break
            start_blk, = struct.unpack(">I", e[8:12])
            name = e[16:48].split(b"\0")[0].decode("mac-roman", "replace")
            ptype = e[48:80].split(b"\0")[0].decode("mac-roman", "replace")
            out.append((name, ptype, start_blk * 512))
    return out


def volume_state(raw, offset):  # noqa
    """('H+'|'HFS'|None, cleanly_unmounted)"""
    with open(raw, "rb") as f:
        f.seek(offset + 1024)
        hdr = f.read(512)
    if len(hdr) < 16:
        return None, False
    sig = hdr[:2]
    if sig in (b"H+", b"HX"):
        attrs, = struct.unpack(">I", hdr[4:8])
        return sig.decode(), bool(attrs & UNMOUNTED)
    if sig == b"BD":
        # Plain HFS — OR the HFS WRAPPER that every OS 8.1+ HFS+ volume
        # carries for old ROMs. The wrapper's own flag is NOT the answer:
        # it is a stub the running system does not mount, so it can read
        # dirty on a perfectly clean machine. Checking it and stopping is
        # how this script first reported the human-verified Aug 3 oracle
        # as dirty. Follow drEmbedSigWord to the real volume.
        embed_sig = hdr[124:126]
        if embed_sig == b"H+":
            alblksiz, = struct.unpack(">I", hdr[20:24])
            albl_st, = struct.unpack(">H", hdr[28:30])
            start_blk, = struct.unpack(">H", hdr[126:128])
            embed = offset + albl_st * 512 + start_blk * alblksiz
            with open(raw, "rb") as f:
                f.seek(embed + 1024)
                inner = f.read(16)
            if inner[:2] in (b"H+", b"HX"):
                attrs, = struct.unpack(">I", inner[4:8])
                return "HFS+ (in wrapper)", bool(attrs & UNMOUNTED)
            return "HFS+ wrapper, embedded volume unreadable", False
        atrb, = struct.unpack(">H", hdr[10:12])
        return "HFS", bool(atrb & UNMOUNTED)
    return None, False


def check(path):
    raw, tmp = raw_of(path)
    try:
        found = False
        ok = True
        for name, ptype, off in partitions(raw):
            if "HFS" not in ptype:
                continue
            kind, clean = volume_state(raw, off)
            if kind is None:
                continue
            found = True
            ok = ok and clean
            print(f"  {os.path.basename(path)}  [{name}] {kind}: "
                  f"{'CLEAN' if clean else 'DIRTY — will run Disk First Aid'}")
        if not found:
            print(f"  {os.path.basename(path)}: no HFS volume found")
            return False
        return ok
    finally:
        if tmp:
            os.unlink(tmp)


if __name__ == "__main__":
    good = True
    for p in sys.argv[1:]:
        good = check(p) and good
    sys.exit(0 if good else 1)
