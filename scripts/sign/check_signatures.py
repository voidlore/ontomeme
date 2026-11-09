#!/usr/bin/env python3
"""Classify Ontomeme's macOS and Windows artifacts by code-signing state.

Runs anywhere python3 and the openssl CLI run (no spctl, stapler or
signtool), so the Linux release job can prove what it is about to publish.

    python3 -I scripts/sign/check_signatures.py [--json]
        [--expect-macos=adhoc|signed|developer-id|stapled]
        [--expect-windows=unsigned|signed] ARTIFACT...

An ARTIFACT is a macOS .zip (Godot's export or the packaged one), an .app
directory, a Windows .exe, a .zip holding one, or a bare Mach-O file.

macOS levels, lowest first:
  unsigned      a Mach-O under Contents/MacOS has no LC_CODE_SIGNATURE
  adhoc         the CodeDirectory has the adhoc flag, or the CMS blob is empty
  signed        a CMS signature whose leaf is not a Developer ID certificate
  developer-id  leaf CN 'Developer ID Application: ...', chain holding
                'Developer ID Certification Authority'
  stapled       developer-id plus the notarization ticket, Contents/CodeResources
Windows levels: unsigned, signed (a PKCS#7 WIN_CERTIFICATE in the PE security
directory). Every exe must also keep Godot's embedded pack: a 'pck' section
whose raw data starts with GDPC.

An --expect-* holds when every artifact of that platform reaches at least that
level. Exit 0 when all hold, 1 when one fails or an artifact has a problem
(each printed as one FAIL line on stderr), 2 on a usage error or an artifact
that cannot be read.
"""

import argparse
import base64
import contextlib
import datetime
import functools
import hashlib
import json
import mmap
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.parsers.expat
import zipfile
import zlib

MACOS_LEVELS = ("unsigned", "adhoc", "signed", "developer-id", "stapled")
WINDOWS_LEVELS = ("unsigned", "signed")
LEVELS = {"macos": MACOS_LEVELS, "windows": WINDOWS_LEVELS}
PLATFORM_NAMES = {"macos": "macOS", "windows": "Windows"}

DEVELOPER_ID_LEAF = "Developer ID Application:"
DEVELOPER_ID_CA = "Developer ID Certification Authority"

# Mach-O (mach-o/loader.h, mach-o/fat.h) and code signing (cs_blobs.h).
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
THIN_HEADERS = {  # first four bytes -> (struct byte order, header size)
    b"\xcf\xfa\xed\xfe": ("<", 32),
    b"\xce\xfa\xed\xfe": ("<", 28),
    b"\xfe\xed\xfa\xcf": (">", 32),
    b"\xfe\xed\xfa\xce": (">", 28),
}
MAX_FAT_ARCHS = 45  # a Java class file also starts with 0xcafebabe; its major version is >= 45
LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_BLOBWRAPPER = 0xFADE0B01
CSSLOT_ENTITLEMENTS = 5
CSSLOT_SIGNATURESLOT = 0x10000
CS_ADHOC = 0x2
CS_RUNTIME = 0x10000
CD_FLAG_NAMES = (
    (0x1, "host"),
    (CS_ADHOC, "adhoc"),
    (0x100, "hard"),
    (0x200, "kill"),
    (0x400, "expires"),
    (0x800, "restrict"),
    (0x1000, "enforcement"),
    (0x2000, "library-validation"),
    (CS_RUNTIME, "runtime"),
    (0x20000, "linker-signed"),
)
CPU_NAMES = {
    7: "i386",
    0x01000007: "x86_64",
    12: "arm",
    0x0100000C: "arm64",
    0x0200000C: "arm64_32",
    18: "ppc",
    0x01000012: "ppc64",
}

# PE/COFF (winnt.h, wintrust.h).
PE32_MAGIC = 0x10B
PE32_PLUS_MAGIC = 0x20B
IMAGE_DIRECTORY_ENTRY_SECURITY = 4
WIN_CERT_REVISION_2_0 = 0x0200
WIN_CERT_TYPE_PKCS_SIGNED_DATA = 0x0002
GODOT_PCK_SECTION = "pck"
GODOT_PCK_MAGIC = b"GDPC"


class ArtifactError(Exception):
    """The artifact cannot be read or holds nothing this script knows."""


class FormatError(Exception):
    """A binary is malformed; reported as a problem with that artifact."""


class ToolError(Exception):
    """A tool this script needs (openssl) is missing."""


# --- reading bytes ---------------------------------------------------------


@contextlib.contextmanager
def mapped(f):
    """Map an open binary file read-only; an empty file maps to b''."""
    if os.fstat(f.fileno()).st_size == 0:
        yield b""
        return
    view = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    try:
        yield view
    finally:
        view.close()


@contextlib.contextmanager
def mapped_path(path):
    with open(path, "rb") as f, mapped(f) as buf:
        yield buf


class DirTree:
    """Files under a directory, optionally only those under one subdirectory."""

    def __init__(self, base, only=""):
        self.base = base
        self.only = only

    def files(self):
        top = os.path.join(self.base, self.only) if self.only else self.base
        for parent, dirs, names in os.walk(top):
            dirs.sort()
            for name in sorted(names):
                full = os.path.join(parent, name)
                if os.path.isfile(full) and not os.path.islink(full):
                    yield os.path.relpath(full, self.base).replace(os.sep, "/")

    def exists(self, rel):
        return os.path.isfile(os.path.join(self.base, rel))

    def head(self, rel, size):
        with open(os.path.join(self.base, rel), "rb") as f:
            return f.read(size)

    def open(self, rel):
        return mapped_path(os.path.join(self.base, rel))


class ZipTree:
    """Files inside a zip, read with zipfile (no unzip needed)."""

    def __init__(self, archive):
        self.archive = archive
        self.names = [
            info.filename
            for info in archive.infolist()
            if not info.is_dir() and (info.external_attr >> 16) & 0o170000 != 0o120000
        ]
        self.known = set(self.names)

    def files(self):
        return iter(self.names)

    def exists(self, rel):
        return rel in self.known

    def head(self, rel, size):
        with self.archive.open(rel) as f:
            return f.read(size)

    @contextlib.contextmanager
    def open(self, rel):
        # A Mach-O's signature sits at the end of each slice, so copy the
        # member out once and map it rather than seek inside the deflate stream.
        with self.archive.open(rel) as src, tempfile.TemporaryFile() as tmp:
            shutil.copyfileobj(src, tmp, 1 << 20)
            tmp.flush()
            with mapped(tmp) as buf:
                yield buf


def unpack(fmt, buf, offset, what):
    if offset < 0 or offset + struct.calcsize(fmt) > len(buf):
        raise FormatError(f"{what} runs past the end of the data")
    return struct.unpack_from(fmt, buf, offset)


def c_string(buf, offset, what):
    if offset >= len(buf):
        raise FormatError(f"{what} offset is out of range")
    end = buf.find(b"\0", offset)
    if end < 0:
        raise FormatError(f"{what} is not NUL-terminated")
    return bytes(buf[offset:end]).decode("utf-8", "replace")


def der_object(data):
    """The first DER object in data, without trailing padding.

    Indefinite-length BER (Apple's codesign writes it) is returned whole;
    openssl reads one object and ignores what follows.
    """
    if len(data) < 2:
        raise FormatError("the PKCS#7 signature is empty")
    first = data[1]
    if first < 0x80:
        total = 2 + first
    elif first == 0x80:
        return bytes(data)
    else:
        count = first & 0x7F
        total = 2 + count + int.from_bytes(data[2 : 2 + count], "big")
    if total > len(data):
        raise FormatError("the PKCS#7 signature is truncated")
    return bytes(data[:total])


def jsonable(value):
    """A parsed plist value as JSON: data as base64, dates as ISO 8601."""
    if isinstance(value, dict):
        return {key: jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [jsonable(item) for item in value]
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    if isinstance(value, datetime.datetime):
        return value.isoformat()
    return value


def parse_plist(data):
    """A plist (XML or binary) as JSON values, or None when it does not parse."""
    try:
        return jsonable(plistlib.loads(bytes(data)))
    except (plistlib.InvalidFileException, ValueError, xml.parsers.expat.ExpatError):
        return None


def privacy_strings(info):
    """The NS...UsageDescription strings of a parsed Info.plist."""
    if not isinstance(info, dict):
        return None
    return {key: value for key, value in sorted(info.items())
            if key.startswith("NS") and key.endswith("UsageDescription")}


# --- certificates (openssl) ------------------------------------------------

PEM_CERT = re.compile(rb"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----\n?", re.S)


def run_openssl(args, data):
    try:
        return subprocess.run(["openssl", *args], input=data, capture_output=True, timeout=60, check=False)
    except FileNotFoundError as exc:
        raise ToolError("openssl is not on PATH; it is needed to read signatures") from exc


def parse_names(text):
    """Parse `openssl x509 -subject -issuer -enddate -nameopt multiline` output."""
    names = {"subject": [], "issuer": []}
    not_after = ""
    section = None
    for line in text.splitlines():
        if line in ("subject=", "issuer="):
            section = line[:-1]
        elif line.startswith("notAfter="):
            not_after = line.split("=", 1)[1].strip()
            section = None
        elif section and line[:1].isspace() and " = " in line:
            attr, value = line.split(" = ", 1)
            names[section].append((attr.strip(), value.strip()))
    return tuple(names["subject"]), tuple(names["issuer"]), not_after


def common_name(name):
    return next((value for attr, value in name if attr == "commonName"), "")


@functools.lru_cache(maxsize=None)
def read_certificates(der):
    """Every certificate in a PKCS#7/CMS signature, as (subject, issuer, not_after)."""
    listed = run_openssl(["pkcs7", "-inform", "DER", "-print_certs"], der)
    if listed.returncode != 0:
        raise FormatError("openssl cannot read the PKCS#7 signature")
    pems = PEM_CERT.findall(listed.stdout)
    if not pems:
        raise FormatError("the PKCS#7 signature holds no certificates")
    certs = []
    for pem in pems:
        shown = run_openssl(
            ["x509", "-noout", "-subject", "-issuer", "-enddate", "-nameopt", "multiline,utf8,-esc_msb"], pem
        )
        if shown.returncode != 0:
            raise FormatError("openssl cannot read a certificate in the signature")
        certs.append(parse_names(shown.stdout.decode("utf-8", "replace")))
    return tuple(certs)


def leaf_certificate(certs):
    """The certificate that issued none of the others."""
    for cert in certs:
        if not any(other is not cert and other[1] == cert[0] for other in certs):
            return cert
    return certs[0]


def describe_signer(der):
    """The leaf signer of a signature, and whether it is a Developer ID one."""
    certs = read_certificates(der_object(der))
    leaf = leaf_certificate(certs)
    subject_cn = common_name(leaf[0])
    chain = [common_name(cert[0]) for cert in certs]
    issuer_cn = common_name(leaf[1])
    developer_id = subject_cn.startswith(DEVELOPER_ID_LEAF) and DEVELOPER_ID_CA in {issuer_cn, *chain}
    signer = {
        "subject_cn": subject_cn,
        "subject": ", ".join(f"{attr}={value}" for attr, value in leaf[0]),
        "issuer_cn": issuer_cn,
        "not_after": leaf[2],
        "chain": chain,
    }
    return signer, developer_id


# --- Mach-O ----------------------------------------------------------------


def is_macho(head):
    if head[:4] in THIN_HEADERS:
        return True
    if len(head) < 8:
        return False
    magic, count = struct.unpack_from(">II", head, 0)
    return magic in (FAT_MAGIC, FAT_MAGIC_64) and 0 < count < MAX_FAT_ARCHS


def arch_name(cputype, subtype):
    if cputype == 0x0100000C and subtype & 0xFFFFFF == 2:
        return "arm64e"
    return CPU_NAMES.get(cputype, f"cpu{cputype:#x}")


def thin_header(buf, base):
    header = THIN_HEADERS.get(bytes(buf[base : base + 4]))
    if header is None:
        raise FormatError("a slice does not start with a Mach-O header")
    return header


def macho_slices(buf):
    """(arch, offset, size) of each architecture in a thin or fat Mach-O."""
    magic = unpack(">I", buf, 0, "Mach-O header")[0]
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        order, _ = thin_header(buf, 0)
        cputype, subtype = unpack(order + "II", buf, 4, "Mach-O header")
        return [(arch_name(cputype, subtype), 0, len(buf))]
    count = unpack(">I", buf, 4, "fat header")[0]
    fmt, entry = (">IIIII", 20) if magic == FAT_MAGIC else (">IIQQII", 32)
    slices = []
    for index in range(count):
        cputype, subtype, offset, size = unpack(fmt, buf, 8 + index * entry, "fat arch table")[:4]
        if offset + size > len(buf):
            raise FormatError(f"fat arch {index} runs past the end of the file")
        slices.append((arch_name(cputype, subtype), offset, size))
    return slices


def code_signature(buf, base, size):
    """The LC_CODE_SIGNATURE data of the slice at base, or None when unsigned."""
    order, header_size = thin_header(buf, base)
    ncmds, sizeofcmds = unpack(order + "II", buf, base + 16, "Mach-O header")
    at = base + header_size
    stop = at + sizeofcmds
    if stop > base + size:
        raise FormatError("load commands run past the end of the slice")
    for _ in range(ncmds):
        cmd, cmdsize = unpack(order + "II", buf, at, "load command")
        if cmdsize < 8 or at + cmdsize > stop:
            raise FormatError("a load command has a bad size")
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = unpack(order + "II", buf, at + 8, "LC_CODE_SIGNATURE")
            if dataoff + datasize > size:
                raise FormatError("LC_CODE_SIGNATURE points past the end of the slice")
            return bytes(buf[base + dataoff : base + dataoff + datasize])
        at += cmdsize
    return None


def superblob_slots(sig):
    """(slot type, blob magic, blob bytes) for each blob in an embedded signature."""
    magic, length, count = unpack(">III", sig, 0, "code signature SuperBlob")
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        raise FormatError(f"code signature magic is {magic:#x}, not {CSMAGIC_EMBEDDED_SIGNATURE:#x}")
    if length > len(sig):
        raise FormatError("code signature SuperBlob is truncated")
    slots = []
    for index in range(count):
        slot, offset = unpack(">II", sig, 12 + index * 8, "SuperBlob index")
        blob_magic, blob_length = unpack(">II", sig, offset, "SuperBlob blob")
        if blob_length < 8 or offset + blob_length > length:
            raise FormatError(f"SuperBlob slot {slot:#x} has a bad length")
        slots.append((slot, blob_magic, sig[offset : offset + blob_length]))
    return slots


def code_directory(blob):
    version, flags, _hash_offset, ident_offset = unpack(">IIII", blob, 8, "CodeDirectory")
    identifier = c_string(blob, ident_offset, "CodeDirectory identifier")
    team_id = None
    if version >= 0x20200:
        team_offset = unpack(">I", blob, 48, "CodeDirectory teamOffset")[0]
        if team_offset:
            team_id = c_string(blob, team_offset, "CodeDirectory team ID")
    return flags, identifier, team_id


def flag_names(flags):
    return [name for bit, name in CD_FLAG_NAMES if flags & bit]


def classify_slice(sig):
    """Level, reason and details of one architecture's signature."""
    if sig is None:
        return {"level": "unsigned", "reason": "no code signature (LC_CODE_SIGNATURE)"}
    slots = superblob_slots(sig)
    directories = [blob for _slot, magic, blob in slots if magic == CSMAGIC_CODEDIRECTORY]
    if not directories:
        raise FormatError("the code signature has no CodeDirectory")
    flags, identifier, team_id = code_directory(directories[0])
    for extra in directories[1:]:
        flags |= code_directory(extra)[0]
    cms = next((blob for slot, _magic, blob in slots if slot == CSSLOT_SIGNATURESLOT), None)
    entitlements = next((blob for slot, _magic, blob in slots if slot == CSSLOT_ENTITLEMENTS), None)
    result = {
        "flags": f"{flags:#x}",
        "flag_names": flag_names(flags),
        "identifier": identifier,
        "team_id": team_id,
        "entitlements_sha256": hashlib.sha256(entitlements[8:]).hexdigest() if entitlements else None,
        "entitlements": parse_plist(entitlements[8:]) if entitlements else None,
        "signer": None,
    }
    if cms is not None and unpack(">I", cms, 0, "CMS blob")[0] != CSMAGIC_BLOBWRAPPER:
        raise FormatError("the signature slot does not hold a CMS blob wrapper")
    if flags & CS_ADHOC or cms is None or len(cms) <= 8:
        result.update(level="adhoc", reason="ad-hoc signature, no signing certificate")
        return result
    signer, developer_id = describe_signer(cms[8:])
    result["signer"] = signer
    if developer_id:
        result.update(level="developer-id", reason=f"signed by '{signer['subject_cn']}'")
    else:
        result.update(
            level="signed",
            reason=f"signed by '{signer['subject_cn']}', not a Developer ID Application certificate",
        )
    return result


def inspect_macho(buf, path):
    """One entry per architecture of the Mach-O in buf; a malformed one carries a problem."""
    try:
        slices = macho_slices(buf)
    except FormatError as exc:
        return [{"path": path, "arch": "?", "level": "unsigned", "reason": "unreadable Mach-O", "problem": str(exc)}]
    entries = []
    for arch, offset, size in slices:
        entry = {"path": path, "arch": arch}
        try:
            entry.update(classify_slice(code_signature(buf, offset, size)))
        except FormatError as exc:
            entry.update(level="unsigned", reason="unreadable signature", problem=str(exc))
        entries.append(entry)
    return entries


def rank(platform, level):
    return LEVELS[platform].index(level)


def macos_report(artifact, path):
    """A macOS report; bundle-only fields stay None for a bare Mach-O."""
    return {"artifact": artifact, "platform": "macos", "path": path, "code_resources": None, "ticket": None,
            "info_plist_sha256": None, "privacy": None, "problems": []}


def summarize_macos(report, binaries, ticket):
    """Set the report's level from its lowest binary, then the ticket."""
    report["binaries"] = binaries
    for entry in binaries:
        if "problem" in entry:
            report["problems"].append(f"{entry['path']} {entry['arch']}: {entry['problem']}")
    if not binaries:
        report.update(level="unsigned", reason="no Mach-O executable under Contents/MacOS")
        report["problems"].append("no Mach-O executable under Contents/MacOS")
        return report
    lowest = min(binaries, key=lambda entry: rank("macos", entry["level"]))
    report["level"] = lowest["level"]
    report["reason"] = lowest["reason"]
    if any(entry["level"] != lowest["level"] for entry in binaries):
        report["reason"] = f"{lowest['path']} {lowest['arch']}: {lowest['reason']}"
    if report["level"] == "developer-id":
        if ticket:
            report.update(level="stapled", reason=f"{lowest['reason']}, notarization ticket stapled")
        elif ticket is False:
            report["reason"] = f"{lowest['reason']}; no notarization ticket at Contents/CodeResources"
    return report


def inspect_bundle(tree, root, artifact):
    contents = f"{root}/Contents/"
    binaries = []
    for rel in tree.files():
        if not rel.startswith((contents + "MacOS/", contents + "Frameworks/")):
            continue
        if not is_macho(tree.head(rel, 8)):
            continue
        with tree.open(rel) as buf:
            binaries.extend(inspect_macho(buf, rel[len(root) + 1 :]))
    report = macos_report(artifact, root)
    report["code_resources"] = tree.exists(contents + "_CodeSignature/CodeResources")
    report["ticket"] = tree.exists(contents + "CodeResources")
    if tree.exists(contents + "Info.plist"):
        with tree.open(contents + "Info.plist") as buf:
            report["info_plist_sha256"] = hashlib.sha256(buf).hexdigest()
            report["privacy"] = privacy_strings(parse_plist(buf))
    return summarize_macos(report, binaries, report["ticket"])


# --- Windows PE -------------------------------------------------------------


def pe_layout(buf):
    """(sections, security directory (offset, size)) of a PE image."""
    if bytes(buf[:2]) != b"MZ":
        raise FormatError("not a PE file (no MZ header)")
    pe_offset = unpack("<I", buf, 0x3C, "DOS header")[0]
    if bytes(buf[pe_offset : pe_offset + 4]) != b"PE\0\0":
        raise FormatError("not a PE file (no PE signature)")
    section_count, _, _, _, optional_size = unpack("<HIIIH", buf, pe_offset + 6, "COFF header")
    optional = pe_offset + 24
    magic = unpack("<H", buf, optional, "optional header")[0]
    if magic == PE32_PLUS_MAGIC:
        count_at, directories = optional + 108, optional + 112
    elif magic == PE32_MAGIC:
        count_at, directories = optional + 92, optional + 96
    else:
        raise FormatError(f"unknown PE optional header magic {magic:#x}")
    security = (0, 0)
    if unpack("<I", buf, count_at, "optional header")[0] > IMAGE_DIRECTORY_ENTRY_SECURITY:
        security = unpack("<II", buf, directories + IMAGE_DIRECTORY_ENTRY_SECURITY * 8, "data directory")
    sections = []
    table = optional + optional_size
    for index in range(section_count):
        raw_name, _, _, raw_size, raw_offset = unpack("<8sIIII", buf, table + index * 40, "section table")
        name = raw_name.rstrip(b"\0").decode("ascii", "replace")
        sections.append((name, raw_offset, raw_size))
    return sections, security


def authenticode_der(buf, offset, size):
    """The PKCS#7 inside the first PKCS_SIGNED_DATA WIN_CERTIFICATE."""
    if offset + size > len(buf) or size < 8:
        raise FormatError("the security directory points past the end of the file")
    at, end = offset, offset + size
    while at + 8 <= end:
        length, revision, cert_type = unpack("<IHH", buf, at, "WIN_CERTIFICATE")
        if length < 8 or at + length > end:
            raise FormatError("a WIN_CERTIFICATE has a bad length")
        if revision == WIN_CERT_REVISION_2_0 and cert_type == WIN_CERT_TYPE_PKCS_SIGNED_DATA:
            return bytes(buf[at + 8 : at + length])
        at += (length + 7) & ~7
    raise FormatError("no WIN_CERTIFICATE with revision 0x0200 and type PKCS_SIGNED_DATA")


def pck_state(buf, sections):
    section = next((s for s in sections if s[0] == GODOT_PCK_SECTION), None)
    if section is None:
        return "missing", "no 'pck' section: the embedded Godot pack is missing"
    _, raw_offset, raw_size = section
    if raw_size < 4 or bytes(buf[raw_offset : raw_offset + 4]) != GODOT_PCK_MAGIC:
        return "corrupt", "the 'pck' section does not start with GDPC"
    return "intact", None


def inspect_pe(buf, path, artifact):
    report = {"artifact": artifact, "platform": "windows", "path": path, "signer": None, "pck": None,
              "problems": []}
    try:
        sections, (offset, size) = pe_layout(buf)
    except FormatError as exc:
        report.update(level="unsigned", reason="unreadable PE")
        report["problems"].append(str(exc))
        return report
    report["pck"], pck_problem = pck_state(buf, sections)
    if pck_problem:
        report["problems"].append(pck_problem)
    if size == 0:
        report.update(level="unsigned", reason="no Authenticode signature: the security directory is empty")
        return report
    try:
        signer, _ = describe_signer(authenticode_der(buf, offset, size))
    except FormatError as exc:
        report.update(level="unsigned", reason="unreadable Authenticode signature")
        report["problems"].append(str(exc))
        return report
    report.update(level="signed", reason=f"signed by '{signer['subject_cn']}'", signer=signer)
    return report


# --- artifacts --------------------------------------------------------------


def bundle_root(rel):
    """The outermost 'X.app' directory holding rel as X.app/Contents/..., or None."""
    parts = rel.split("/")
    for index, part in enumerate(parts[:-2]):
        if part.endswith(".app") and parts[index + 1] == "Contents":
            return "/".join(parts[: index + 1])
    return None


def inspect_tree(tree, artifact):
    bundles, exes = [], []
    for rel in tree.files():
        root = bundle_root(rel)
        if root is not None:
            if root not in bundles:
                bundles.append(root)
        elif rel.lower().endswith(".exe"):
            exes.append(rel)
    if not bundles and not exes:
        raise ArtifactError("holds no .app bundle and no .exe")
    reports = [inspect_bundle(tree, root, artifact) for root in bundles]
    for rel in exes:
        with tree.open(rel) as buf:
            reports.append(inspect_pe(buf, rel, artifact))
    return reports


def inspect_artifact(path):
    name = os.path.basename(os.path.normpath(path))
    if os.path.isdir(path):
        full = os.path.abspath(path)
        if full.endswith(".app"):
            return inspect_tree(DirTree(os.path.dirname(full), os.path.basename(full)), path)
        return inspect_tree(DirTree(full), path)
    try:
        with open(path, "rb") as f:
            head = f.read(8)
    except OSError as exc:
        raise ArtifactError(exc.strerror or str(exc)) from exc
    if head[:2] == b"MZ":
        with mapped_path(path) as buf:
            return [inspect_pe(buf, name, path)]
    if is_macho(head):
        with mapped_path(path) as buf:
            binaries = inspect_macho(buf, name)
        return [summarize_macos(macos_report(path, name), binaries, None)]
    if zipfile.is_zipfile(path):
        try:
            with zipfile.ZipFile(path) as archive:
                return inspect_tree(ZipTree(archive), path)
        except (zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error, EOFError) as exc:
            raise ArtifactError(f"bad zip: {exc}") from exc
    raise ArtifactError("not a zip, .app, PE or Mach-O file")


def evaluate(reports, expectations):
    """One-line FAIL reasons: problems, unmet expectations, unchecked expectations."""
    failures = []
    for report in reports:
        label = f"{report['artifact']}: {PLATFORM_NAMES[report['platform']]} {report['path']}"
        for problem in report["problems"]:
            failures.append(f"{label}: {problem}")
        expected = expectations.get(report["platform"])
        if expected and rank(report["platform"], report["level"]) < rank(report["platform"], expected):
            failures.append(f"{label} is {report['level']}, expected {expected} ({report['reason']})")
    for platform, expected in expectations.items():
        if expected and not any(report["platform"] == platform for report in reports):
            failures.append(
                f"no {PLATFORM_NAMES[platform]} artifact found to check --expect-{platform}={expected}"
            )
    return failures


def binary_line(entry):
    line = f"  {entry['path']} {entry['arch']}: {entry['level']}"
    if "flags" in entry:
        line += f", flags {entry['flags']} ({', '.join(entry['flag_names']) or 'none'})"
        line += f", identifier {entry['identifier']}"
        if entry.get("team_id"):
            line += f", team {entry['team_id']}"
    elif entry["level"] == "unsigned":
        line += f" ({entry['reason']})"
    return line


def signer_line(signer, indent):
    return (f"{indent}signer: {signer['subject_cn']} (issuer {signer['issuer_cn'] or '?'}, "
            f"expires {signer['not_after'] or '?'})")


def text_lines(report):
    head = f"{report['artifact']}: {PLATFORM_NAMES[report['platform']]} {report['path']}: {report['level']}"
    lines = [f"{head} ({report['reason']})"]
    if report["platform"] == "macos":
        for entry in report["binaries"]:
            lines.append(binary_line(entry))
            if entry.get("signer"):
                lines.append(signer_line(entry["signer"], "    "))
        if report["code_resources"] is not None:
            lines.append(f"  _CodeSignature/CodeResources: {'present' if report['code_resources'] else 'absent'}")
            lines.append(f"  notarization ticket (Contents/CodeResources): {'present' if report['ticket'] else 'absent'}")
    else:
        if report["signer"]:
            lines.append(signer_line(report["signer"], "  "))
        if report["pck"]:
            detail = " (starts with GDPC)" if report["pck"] == "intact" else ""
            lines.append(f"  pck section: {report['pck']}{detail}")
    return lines


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="check_signatures.py",
        description="Classify macOS and Windows artifacts by code-signing state.",
    )
    parser.add_argument("--json", action="store_true", help="print a JSON report on stdout")
    parser.add_argument("--expect-macos", choices=MACOS_LEVELS[1:], metavar="LEVEL",
                        help="fail unless every macOS artifact is at least LEVEL "
                             "(adhoc, signed, developer-id, stapled)")
    parser.add_argument("--expect-windows", choices=WINDOWS_LEVELS, metavar="LEVEL",
                        help="fail unless every Windows exe is at least LEVEL (unsigned, signed)")
    parser.add_argument("artifacts", nargs="+", metavar="ARTIFACT")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    reports, errors = [], []
    for path in args.artifacts:
        try:
            reports.extend(inspect_artifact(path))
        except (ArtifactError, ToolError, OSError) as exc:
            errors.append(f"{path}: {exc}")
    failures = evaluate(reports, {"macos": args.expect_macos, "windows": args.expect_windows})
    if args.json:
        payload = {"ok": not errors and not failures, "artifacts": reports, "failures": failures, "errors": errors}
        print(json.dumps(payload, indent=2))
    else:
        for report in reports:
            print("\n".join(text_lines(report)))
    for line in errors:
        print(f"ERROR {line}", file=sys.stderr)
    for line in failures:
        print(f"FAIL {line}", file=sys.stderr)
    if errors:
        return 2
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
