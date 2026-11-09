#!/usr/bin/env python3
"""List the files a Godot 4 export packs into its PCK (formats v2 to v4).

    python3 -I scripts/pck_list.py [--long | --cat | --extract <dir>] <artifact>

<artifact> is a .pck, a self-contained executable with its pack embedded
(.x86_64, .exe), or a .zip / .tar.gz holding one: a macOS export zip is read
at <name>.app/Contents/Resources/<name>.pck, a Windows zip at its .exe, a
Linux tarball at its .x86_64.

Prints each packed path (no res:// prefix), one per line, in pack order.
  --long          a "# ..." summary line, then "<size><TAB><path>" lines
  --cat           write the bytes that hold the pack (the executable or .pck,
                  unzipped when it came in an archive) to stdout
  --extract DIR   write each packed file under DIR, for grepping
Exits 1 when the artifact holds no readable pack, 2 on bad arguments.

Follows core/io/file_access_pack.cpp: magic "GDPC", then u32 version, major,
minor, patch and flags, u64 file_base; v3 and v4 add a u64 directory offset
from the pack start, v2 has 16 reserved u32 and the directory right after.
The directory is a u32 count, then per file: u32 length, path (NUL padded),
u64 offset, u64 size, 16-byte md5, u32 flags. An executable with an embedded
pack ends with <u64 pack size>"GDPC", the pack sitting just before that, and
the export also points a section named "pck" (PE on Windows, ELF on Linux)
at it. Godot reads that section first, which still finds the pack in a
signed .exe, whose certificate table follows the trailer; so does this.
Stdlib only.
"""

import argparse
import io
import os
import struct
import sys
import tarfile
import zipfile
from typing import List, NamedTuple, Tuple

MAGIC = b"GDPC"
PCK_SECTION = b"pck"   # the section an export points at the embedded pack
VERSIONS = (2, 3, 4)
PACK_DIR_ENCRYPTED = 1 << 0
PACK_REL_FILEBASE = 1 << 1
PACK_FILE_REMOVAL = 1 << 1
ENTRY_FIXED_BYTES = 4 + 8 + 8 + 16 + 4   # length, offset, size, md5, flags
EXECUTABLE_SUFFIXES = (".exe", ".x86_64", ".x86_32", ".arm64", ".arm32")


class PckError(Exception):
    """The artifact holds no pack this script can read."""


class Entry(NamedTuple):
    path: str
    offset: int   # of the file's bytes, from the start of the data
    size: int
    flags: int


class Pack(NamedTuple):
    label: str        # what was read: the file, or archive!member
    version: int
    godot: str        # the engine version that wrote it, "4.7.2"
    flags: int
    entries: List[Entry]


class Reader:
    """Little-endian reads that fail as PckError, not struct.error."""

    def __init__(self, data: bytes, pos: int) -> None:
        self.data = data
        self.pos = pos

    def take(self, n: int) -> bytes:
        if n < 0 or self.pos + n > len(self.data):
            raise PckError("the pack is cut short at byte %d" % self.pos)
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]


def _c_name(raw: bytes) -> bytes:
    """A NUL-terminated name, as strcmp sees it."""
    return raw.split(b"\0", 1)[0]


def _pe_pck_section(data: bytes) -> int:
    """PointerToRawData of a Windows exe's "pck" section (OS_Windows)."""
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        return -1
    count, = struct.unpack_from("<H", data, pe + 6)        # NumberOfSections
    opt_size, = struct.unpack_from("<H", data, pe + 20)    # SizeOfOptionalHeader
    table = pe + 24 + opt_size
    for i in range(count):
        header = table + 40 * i
        if _c_name(data[header:header + 8]) == PCK_SECTION:
            return struct.unpack_from("<I", data, header + 20)[0]
    return -1


def _elf_pck_section(data: bytes) -> int:
    """sh_offset of a Linux executable's "pck" section (OS_LinuxBSD)."""
    if data[4] == 1:     # ELFCLASS32
        table, = struct.unpack_from("<I", data, 0x20)
        count, names_index = struct.unpack_from("<HH", data, 0x30)
        entry, at = 40, "<16xII"            # sh_offset, sh_size at 0x10
    elif data[4] == 2:   # ELFCLASS64
        table, = struct.unpack_from("<Q", data, 0x28)
        count, names_index = struct.unpack_from("<HH", data, 0x3C)
        entry, at = 64, "<24xQQ"            # sh_offset, sh_size at 0x18
    else:
        return -1
    names_offset, names_size = struct.unpack_from(at, data, table + names_index * entry)
    names = data[names_offset:names_offset + names_size]
    for i in range(count):
        header = table + i * entry
        name, = struct.unpack_from("<I", data, header)
        if _c_name(names[name:]) == PCK_SECTION:
            return struct.unpack_from(at, data, header)[0]
    return -1


def section_start(data: bytes) -> int:
    """Where an executable's "pck" section says the pack is, or -1.

    The export points that section at the embedded pack, and Godot reads it
    (OS::get_embedded_pck_offset) before it looks for the trailer, so a pack
    is still found after Authenticode signing appends a certificate table to
    the .exe and the trailer is no longer at the end. A header too short or
    malformed to hold a section table means no section, never an error.
    """
    try:
        if data[:2] == b"MZ":
            return _pe_pck_section(data)
        if data[:4] == b"\x7fELF":
            return _elf_pck_section(data)
    except (struct.error, IndexError):
        pass
    return -1


def pack_start(data: bytes) -> int:
    """Where the pack begins, found as Godot finds it (file_access_pack.cpp):
    a GDPC header at 0 (a .pck), else the executable's "pck" section, else
    the <u64 size>GDPC trailer at the end of the file."""
    if data[:4] == MAGIC:
        return 0
    start = section_start(data)
    if start > 0 and data[start:start + 4] == MAGIC:
        return start
    if len(data) >= 12 and data[-4:] == MAGIC:
        size = struct.unpack_from("<Q", data, len(data) - 12)[0]
        start = len(data) - 12 - size
        if 0 <= start and data[start:start + 4] == MAGIC:
            return start
        raise PckError("the trailer says the pack is %d bytes, but no GDPC header is there" % size)
    raise PckError("no Godot pack: no GDPC header at the start, in a \"pck\" section,"
                   " or before a <size>GDPC trailer at the end")


def read_pack(data: bytes, label: str) -> Pack:
    start = pack_start(data)
    r = Reader(data, start + 4)
    version, major, minor, patch, flags = (r.u32() for _ in range(5))
    if version not in VERSIONS:
        raise PckError("pack format v%d is not one this reads (v2 to v4, Godot 4)" % version)
    file_base = r.u64()
    if version >= 3 or flags & PACK_REL_FILEBASE:
        file_base += start
    if version >= 3:
        r.pos = start + r.u64()
    else:
        r.take(16 * 4)   # reserved
    if flags & PACK_DIR_ENCRYPTED:
        raise PckError("the pack's directory is encrypted, so its files can't be listed")
    count = r.u32()
    if count * ENTRY_FIXED_BYTES > len(data) - r.pos:
        raise PckError("the directory claims %d files, more than the pack can hold" % count)
    entries = []
    for _ in range(count):
        raw = r.take(r.u32())
        offset, size = r.u64(), r.u64()
        r.take(16)   # md5
        file_flags = r.u32()
        try:
            path = raw.rstrip(b"\0").decode("utf-8")
        except UnicodeDecodeError:
            raise PckError("a packed path is not UTF-8: %r" % raw) from None
        if path.startswith("res://"):   # v2 packs kept the prefix
            path = path[len("res://"):]
        if file_flags & PACK_FILE_REMOVAL:   # a patch pack deleting a file
            continue
        if file_base + offset + size > len(data):
            raise PckError("%s runs past the end of the pack" % path)
        entries.append(Entry(path, file_base + offset, size, file_flags))
    godot = "%d.%d.%d" % (major, minor, patch)
    return Pack(label, version, godot, flags, entries)


def _pick_member(names: List[str], label: str) -> str:
    """The one archive member that holds the pack."""
    files = [n for n in names if not n.endswith("/")]
    mac = [n for n in files if ".app/Contents/Resources/" in n and n.endswith(".pck")]
    pcks = [n for n in files if n.endswith(".pck")]
    exes = [n for n in files if n.endswith(EXECUTABLE_SUFFIXES) and not n.endswith(".console.exe")]
    for found in (mac, pcks, exes):
        if len(found) == 1:
            return found[0]
        if len(found) > 1:
            raise PckError("%s holds more than one pack: %s" % (label, ", ".join(found)))
    raise PckError("%s holds no .pck and no Godot executable" % label)


def load(path: str) -> Tuple[bytes, str]:
    """The bytes that hold the pack, and a label naming where they came from."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise PckError("can't read %s: %s" % (path, e.strerror)) from None
    try:
        if data[:4] == b"PK\x03\x04":
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                member = _pick_member(z.namelist(), path)
                return z.read(member), "%s!%s" % (path, member)
        if data[:2] == b"\x1f\x8b" or data[257:262] == b"ustar":
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as t:
                member = _pick_member([m.name for m in t.getmembers() if m.isfile()], path)
                return t.extractfile(member).read(), "%s!%s" % (path, member)
    except (zipfile.BadZipFile, tarfile.TarError, EOFError, OSError) as e:
        raise PckError("can't open the archive %s: %s" % (path, e)) from None
    return data, path


def extract(data: bytes, pack: Pack, out_dir: str) -> None:
    root = os.path.realpath(out_dir)
    for e in pack.entries:
        target = os.path.realpath(os.path.join(root, e.path))
        if os.path.isabs(e.path) or not target.startswith(root + os.sep):
            raise PckError("refusing to extract %r outside %s" % (e.path, out_dir))
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(data[e.offset:e.offset + e.size])
        except OSError as err:
            raise PckError("can't extract %s: %s" % (e.path, err.strerror)) from None


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description="List the files packed into a Godot 4 export.")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--long", action="store_true", help="a summary line, then size and path")
    mode.add_argument("--cat", action="store_true", help="write the bytes holding the pack to stdout")
    mode.add_argument("--extract", metavar="DIR", help="write each packed file under DIR")
    ap.add_argument("artifact")
    args = ap.parse_args(argv)
    try:
        data, label = load(args.artifact)
        if args.cat:
            pack_start(data)   # only bytes that hold a pack
            sys.stdout.buffer.write(data)
            return 0
        pack = read_pack(data, label)
        if args.extract:
            extract(data, pack, args.extract)
            return 0
    except PckError as e:
        print("pck_list: %s: %s" % (args.artifact, e), file=sys.stderr)
        return 1
    out = sys.stdout
    if args.long:
        out.write("# %s: pck v%d from Godot %s, flags 0x%x, %d files\n"
                  % (pack.label, pack.version, pack.godot, pack.flags, len(pack.entries)))
    for e in pack.entries:
        out.write("%d\t%s\n" % (e.size, e.path) if args.long else e.path + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
