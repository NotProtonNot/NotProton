#!/usr/bin/env python3
# Development tool. The real patcher lives in the app (NtdllPatcher.swift).
# This is the original Python version, kept for validating patches against
# new CrossOver builds.
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from resolve import PE, SECTION_FLAGS, SECTION_NAME, SECTION_SIZE, resolve, shell_vars  # noqa: E402

# A new build needs its ntdll hash added here and in build-ntdll.sh.
PAYLOAD_BY_CLEAN_SHA = {
    "8b32c9f6f71b4f15fcaccb19b0f2adab9391ae73ad539cae9e136f8ee7d24128": "detour2-whisky-4.7.3.bin",
    "cc8a9035cea0e26c5d333ef220f1becefc27ae44d2cdcdaea3278e8739d26fd9": "detour32-whisky-4.7.3.bin",
    "e4824bda7170ddc77f55357c2be2b256787a79ce1fb8bb54b2794e6200a8132e": "detour2-whisky-4.8.12.bin",
    "9fa20eee518ba7219c5710720814e2fffb5f0b667429bce336bb1cbd234298bc": "detour32-whisky-4.8.12.bin",
    "20111d365e092f3dd787fe04bb3347d5135e68ca77bf91c1e42e4451f0bb0265": "detour2-whisky-4.8.22.bin",
    "f3999711b04a99c991a477c75a9c858580fc502a930c8d730b3d13ddf3339601": "detour32-whisky-4.8.22.bin",
    "006ece15ead59d616287466c243bc7eeef3c99de37f7eb84fcf49efbc0f01aa1": "detour2-whisky-3.1.1.bin",
    "bc463dfc7f03fbfc7e013e2942be993913263069a302d93ef6bc384a4f8daba3": "detour32-whisky-3.1.1.bin",
    "5e4a782ef6c5e79f70cda10083b786fda89f1364c1e4c1de00654ff61d4ea762": "detour2-winecx.bin",
    "0540c0e79b0316a4ecbe884fa88b438ae63a2dcf0b246081a0e9fc0a9a09eb26": "detour32-winecx.bin",
    "04c7200b6645decb7c2d1ba6b0195abc9af83257072558d11aa72cc067ac3377": "detour2.bin",
    "94cc7c14c1e9dcf58ef501015c115f8405c73b2a65cefe31faa5d9e47f36e58b": "detour32.bin",
    "f4fa556a3dc20f6e966a803f5de554359227a61a24cd5b5a2ad88a427ceeec58": "detour2-fex.bin",
    "09474795d6f306163cebab6429819999fcff50e07dbc4b067a90ec4f74a3a7d7": "detour32-fex.bin",
    "7823d71fbce6c9947163bf8b96beb299eabb02878245bcaf6759f2a22e81f071": "detour64-fex.bin",
    "6dff64c00793ce92124f1316985c63783f539f26b392975c70f57637458d2387": "detour2-cx26.bin",
    "2c60ee6b00dd13b7f6cb11017778a041ba6a321eaea194f1fa0dca7eab8403e2": "detour32-cx26.bin",
    "5b388fd48823e905616432fba627eb48f68dc14383963bb213d55db3f691b1b9": "detour2-41069.bin",
    "e7da2a712870222942ef27a80b3bf4fa70fc8545dd1a64bdc7f2fa24a38debc3": "detour32-41069.bin",
    "1b02dcf6ad9d9490870f1127a421c4c0d1471c65ec1574e1e84c05d69801ac7e": "detour2-fex-41069.bin",
    "66b1a244a611795c59a93a9491d17f36c98cd8db9be495004a37864e0e5ed4a5": "detour32-fex-41069.bin",
    "77ca83b2e1a3a1242f9d2d8868328262b2bcfc3f59bacf8b9389ea7e797ea852": "detour64-fex-41069.bin",
    "f489347e59d4e8b43c2b0d2abbff9ee31e2059d45fd75fc04e2f4c0d8b04464a": "detour2-41073.bin",
    "5249b95eea6df765257b2e5212831f511d8f66134abe3c231b8e73d8f5b4707e": "detour32-41073.bin",
    "3d24426735defd222fd9518b094b738dc1c12afd13efc41a855013ed0f825129": "detour2-fex-41073.bin",
    "3ee764335e50709285361e2542731385f0b06e593a76aa84a3c328c278164c4f": "detour32-fex-41073.bin",
    "a6678f9d0818e1cdb325e1ce8a07a540433f544b6f756c52a6ab1cfd3f632408": "detour64-fex-41073.bin",
}

KNOWN_MACHINES = (0x8664, 0x14c, 0xaa64)


def default_payload(src):
    with open(src, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest in PAYLOAD_BY_CLEAN_SHA:
        return PAYLOAD_BY_CLEAN_SHA[digest]
    raise SystemExit(f"{src}: sha256 {digest} matches no known clean ntdll, "
                     f"pass payload.bin as the third argument")


def append_section(pe, d, r):
    """Grows the image by one executable section and returns its file offset."""
    import struct
    raw = r['rawOffset']
    e = struct.unpack_from('<I', d, 0x3c)[0]
    d[pe.table_end:pe.table_end + 40] = struct.pack(
        '<8sIIIIIIHHI', SECTION_NAME, SECTION_SIZE, r['caveRVA'], SECTION_SIZE, raw,
        0, 0, 0, 0, SECTION_FLAGS)
    struct.pack_into('<H', d, e + 6, struct.unpack_from('<H', d, e + 6)[0] + 1)
    struct.pack_into('<I', d, pe.opt + 56, r['caveRVA'] + SECTION_SIZE)
    d.extend(b"\0" * (raw + SECTION_SIZE - len(d)))
    return raw


def main():
    if len(sys.argv) < 2:
        raise SystemExit(f"usage: {sys.argv[0]} <src ntdll.dll> [dst] [payload.bin]")
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else "ntdll.dll.patched"
    here = os.path.dirname(os.path.abspath(__file__))

    r = resolve(src)
    v = shell_vars(src)
    if r['machine'] not in KNOWN_MACHINES:
        raise SystemExit(f"{src}: machine {r['machine']:#x} carries no detour")
    payload_path = sys.argv[3] if len(sys.argv) > 3 \
        else os.path.join(here, default_payload(src))
    detour = open(payload_path, "rb").read()
    payload_rva = int(v['NP_PAYLOAD_RVA'], 16)
    fill = r['fill']
    sites = r.get('sites') or [r]

    pe = PE(src)
    d = bytearray(pe.d)
    if r['placement'] == 'section':
        cave_off = append_section(pe, d, r)
    else:
        cave_off = pe.off(payload_rva)

    if any(b != fill for b in d[cave_off:cave_off + len(detour)]):
        raise SystemExit(f"cave at {cave_off:#x} is not {fill:#02x} pad for {len(detour)} bytes")
    d[cave_off:cave_off + len(detour)] = detour

    hooks = []
    for site in sites:
        bm_off = pe.off(site['hookRVA'])
        stolen = bytes.fromhex(site['stolen'])
        if d[bm_off:bm_off + len(stolen)] != stolen:
            raise SystemExit(f"unexpected hook site at {site['hookRVA']:#x}: "
                             f"{d[bm_off:bm_off + len(stolen)].hex()}")
        if r['machine'] == 0xaa64:
            rel = payload_rva - site['hookRVA']
            if rel % 4 or not -(1 << 27) <= rel < (1 << 27):
                raise SystemExit(f"cave is {rel:#x} from the hook, out of bl range")
            patch = (0x94000000 | ((rel >> 2) & 0x03ffffff)).to_bytes(4, 'little')
        else:
            # E9 rel32 to the shim at the payload start
            rel = payload_rva - (site['hookRVA'] + 5)
            patch = b"\xE9" + rel.to_bytes(4, 'little', signed=True) + b"\xCC" * (len(stolen) - 5)
        assert len(patch) == len(stolen)
        d[bm_off:bm_off + len(patch)] = patch
        hooks.append((site, bm_off, rel, stolen))

    # patch in memory and write once, like a pro
    tmp = dst + ".tmp"
    with open(tmp, "wb") as f:
        f.write(d)
    os.replace(tmp, dst)

    print(f"patched {src} -> {dst}")
    print(f"  payload {os.path.basename(payload_path)}, {len(detour)} bytes at rva "
          f"{payload_rva:#x} (off {cave_off:#x}), cave pad {fill:#02x}")
    for site, bm_off, rel, stolen in hooks:
        print(f"  hook {site['hookRVA']:#x} (off {bm_off:#x}) branch rel {rel:#x} to cave "
              f"entry, stolen {stolen.hex()}")


if __name__ == "__main__":
    main()
