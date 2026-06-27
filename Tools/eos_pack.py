#!/usr/bin/env python3
"""
eos_pack.py - Eos embedded-XBE packer for the Cerbios/Xenium boot stage.

The Xenium PromOS image is:  [ ...flash banks... ][ XeniumOS bank @0x100000:
    u32 decompressed_size, u32 compressed_size, LZ4-block(XBE) ][ kernel @0x180000 ]

This tool swaps ONLY the embedded XBE inside a known-good template image, leaving
the borrowed Cerbios kernel and all bank geometry byte-for-byte identical. That
keeps the kernel's XBE-location expectations satisfied; the single variable is
your launcher XBE.

Usage:
  pack:    python3 eos_pack.py pack  <template.bin> <your_loader.xbe> <out.bin>
  unpack:  python3 eos_pack.py unpack <image.bin> <out.xbe>
  verify:  python3 eos_pack.py verify <image.bin>          (round-trips the payload)
"""
import sys, struct, hashlib
import lz4.block

XBE_REGION_OFF   = 0x100000      # XeniumOS bank base (descriptor + LZ4 XBE)
XBE_REGION_LIMIT = 0x180000      # kernel sits at/after here
REGION_MAX       = XBE_REGION_LIMIT - XBE_REGION_OFF   # 0x80000 = 512KB

def _compress(xbe: bytes) -> bytes:
    # raw LZ4 block, size carried externally in the descriptor (store_size=False)
    return lz4.block.compress(xbe, store_size=False, mode='high_compression', compression=12)

def _decompress(image: bytes, off=XBE_REGION_OFF) -> bytes:
    dec, comp = struct.unpack("<II", image[off:off+8])
    return lz4.block.decompress(image[off+8:off+8+comp], uncompressed_size=dec)

def pack(template_path, xbe_path, out_path):
    img = bytearray(open(template_path, "rb").read())
    xbe = open(xbe_path, "rb").read()
    if xbe[:4] != b"XBEH":
        print("WARNING: input does not start with XBEH magic - is it a real XBE?")
    comp = _compress(xbe)
    blob = struct.pack("<II", len(xbe), len(comp)) + comp
    if len(blob) > REGION_MAX:
        sys.exit("ERROR: descriptor+XBE (0x%X) exceeds XeniumOS bank (0x%X)" % (len(blob), REGION_MAX))
    img[XBE_REGION_OFF:XBE_REGION_LIMIT] = b"\x00" * REGION_MAX
    img[XBE_REGION_OFF:XBE_REGION_OFF+len(blob)] = blob
    open(out_path, "wb").write(img)
    print("packed -> %s  (XBE %d B -> LZ4 %d B, %.0f%% of bank)" %
          (out_path, len(xbe), len(comp), 100*len(blob)/REGION_MAX))
    # self-verify
    back = _decompress(bytes(img))
    assert hashlib.md5(back).hexdigest() == hashlib.md5(xbe).hexdigest(), "round-trip mismatch!"
    print("self-verify: payload round-trips byte-identical  OK")

def unpack(image_path, out_path):
    raw = _decompress(open(image_path, "rb").read())
    open(out_path, "wb").write(raw)
    print("unpacked -> %s  (%d bytes, magic=%r)" % (out_path, len(raw), raw[:4]))

def verify(image_path):
    img = open(image_path, "rb").read()
    raw = _decompress(img)
    re_comp = _compress(raw)
    print("XBE: %d bytes, magic=%r, md5=%s" % (len(raw), raw[:4], hashlib.md5(raw).hexdigest()[:12]))
    print("descriptor decsz=0x%X compsz=0x%X" % struct.unpack("<II", img[XBE_REGION_OFF:XBE_REGION_OFF+8]))
    print("re-compress size 0x%X (informational)" % len(re_comp))

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(__doc__)
    cmd = sys.argv[1]
    if   cmd == "pack"   and len(sys.argv)==5: pack(sys.argv[2], sys.argv[3], sys.argv[4])
    elif cmd == "unpack" and len(sys.argv)==4: unpack(sys.argv[2], sys.argv[3])
    elif cmd == "verify" and len(sys.argv)==3: verify(sys.argv[2])
    else: sys.exit(__doc__)
