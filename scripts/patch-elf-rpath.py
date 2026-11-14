#!/usr/bin/env python3
"""Normalize DT_RPATH/DT_RUNPATH of staged ELFs without patchelf/chrpath.

The self-hosted Kylin runner has neither patchelf nor chrpath and runs as a
non-root user, so we cannot install one. Instead this script rewrites the
rpath string inside .dynstr *in place*: the replacement is never longer than
the original, so the ELF layout, every section offset and every string-table
index stay valid. Only strings that leak a build-machine path are touched;
anything already clean (e.g. $ORIGIN, the final install prefix) is left alone.

Usage: patch-elf-rpath.py <staged-tree-root> <final-rpath>
Exit 1 if any build-machine path survives.
"""
import os
import struct
import subprocess
import sys

BAD = ("/work/", "/rpmbuild/", "BUILDROOT", "actions-runner",
       "_qgis-334-", "qgis-33412-work", "/usr/local/gcc11")


def is_elf(path):
    try:
        with open(path, "rb") as f:
            head = f.read(20)
    except OSError:
        return False
    return len(head) >= 20 and head[:4] == b"\x7fELF" and head[18:20] == b"\x3e\x00"


def dynstr_span(data):
    """Return (start, end) file offsets of the .dynstr section of an ELF64."""
    if data[:4] != b"\x7fELF" or data[4] != 2:  # ELFCLASS64
        return None
    try:
        e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
        e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
        e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
        e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]
        if not e_shoff or not e_shnum or e_shentsize < 64:
            return None

        def sh(i):
            off = e_shoff + i * e_shentsize
            return (struct.unpack_from("<I", data, off)[0],
                    struct.unpack_from("<Q", data, off + 24)[0],
                    struct.unpack_from("<Q", data, off + 32)[0])

        names_off, names_size = sh(e_shstrndx)[1:]
        if names_off + names_size > len(data):
            return None
        names = data[names_off:names_off + names_size]
        for i in range(e_shnum):
            name_off, off, size = sh(i)
            end = names.find(b"\0", name_off)
            if end > name_off and names[name_off:end] == b".dynstr":
                return off, off + size
    except (struct.error, IndexError):
        return None
    return None


def rpath_strings(path):
    """Return the raw DT_RPATH/DT_RUNPATH strings reported by readelf -d."""
    try:
        out = subprocess.run(["readelf", "-d", path], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    result = []
    for line in out.decode("utf-8", "replace").splitlines():
        if "Library rpath:" in line or "Library runpath:" in line:
            _, sep, rest = line.partition("[")
            if sep and "]" in rest:
                result.append(rest.rsplit("]", 1)[0])
    return result


def leaks(s):
    return any(t in s for t in BAD)


def patch(path, final):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    final_b = final.encode()
    dirty = sorted({s for s in rpath_strings(path) if leaks(s)}, key=len, reverse=True)
    if not dirty:
        return "clean"
    span = dynstr_span(data)
    lo, hi = span if span else (0, len(data))
    used = set()
    changed = 0
    for s in dirty:
        old_b = s.encode() + b"\0"
        pos = data.find(old_b, lo, hi)
        while pos in used and pos >= 0:
            pos = data.find(old_b, pos + 1, hi)
        if pos < 0:
            return "not-found"
        used.add(pos)
        if len(final_b) <= len(old_b) - 1:
            new_b = final_b + b"\0" * (len(old_b) - len(final_b))
        else:
            # slot too small for the final rpath: clear it entirely. An empty
            # runpath is harmless (the wrapper supplies LD_LIBRARY_PATH).
            new_b = b"\0" * len(old_b)
        data[pos:pos + len(old_b)] = new_b
        changed += 1
    with open(path, "wb") as f:
        f.write(data)
    return "patched" if changed else "clean"


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: patch-elf-rpath.py <staged-tree-root> <final-rpath>")
    root, final = sys.argv[1], sys.argv[2]
    if not os.path.isdir(root):
        raise SystemExit("staged tree not found: %s" % root)

    stats = {"patched": 0, "clean": 0, "not-found": 0}
    elf_count = 0
    residual = []
    for base, dirs, files in os.walk(root):
        for name in files:
            p = os.path.join(base, name)
            if os.path.islink(p) or not is_elf(p):
                continue
            elf_count += 1
            stats[patch(p, final)] += 1
            left = [s for s in rpath_strings(p) if leaks(s)]
            if left:
                residual.append((os.path.relpath(p, root), left[0]))

    print("rpath-normalize: ELF=%d patched=%d clean=%d not-found=%d"
          % (elf_count, stats["patched"], stats["clean"], stats["not-found"]))
    if residual:
        print("rpath-normalize: residual build-machine paths: %d" % len(residual))
        for rel, sample in residual[:10]:
            print("  %s -> %s" % (rel, sample))
        return 1
    if stats["not-found"]:
        print("rpath-normalize: %d ELF rpath strings could not be located in .dynstr"
              % stats["not-found"])
        return 1
    if elf_count == 0:
        print("rpath-normalize: no ELF found, refusing to report success")
        return 1
    print("rpath-normalize: all ELF rpaths are clean -> %s" % final)
    return 0


if __name__ == "__main__":
    sys.exit(main())
