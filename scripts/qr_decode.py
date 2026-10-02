#!/usr/bin/env python3
"""qr_decode.py -- read the QR code openwrt-mcp draws, so a gate can say "decodable" and mean it.

  qr_decode.py png FILE        a PNG (what `mfa enrol --json` returns as qr_png_base64)
  qr_decode.py art FILE        the half-block text `mfa enrol --qr` prints in the terminal; FILE
                               may hold the command's whole output, the longest block of art
                               lines is the code
  qr_decode.py selftest        the decoder against a code it builds itself, and against the same
                               code damaged

Prints the decoded text and exits 0, or says why not on stderr and exits 1.

Why this exists. A gate that only checks "a PNG came back" would pass a PNG that is a picture of
nothing. This reads the symbol the way a phone does: it finds the modules, reads the format
information, undoes the mask, walks the data in the standard's order, and then checks every
block's Reed-Solomon syndromes, so a code with one module wrong is refused instead of read with
luck. It needs no library, because the router's rootfs has none and the gate has no network.

What it reads: numeric, alphanumeric and byte segments, error-correction level M, versions 1 to 15, which is what
github.com/skip2/go-qrcode produces at level Medium for an otpauth URI of this length. Anything
else is refused by name rather than guessed at.
"""
import struct
import sys
import zlib

# ---- Reed-Solomon over GF(256), the QR field (x^8 + x^4 + x^3 + x^2 + 1) ------------------

EXP = [0] * 512
LOG = [0] * 256
_x = 1
for _i in range(255):
    EXP[_i] = _x
    LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    EXP[_i] = EXP[_i - 255]


def gf_mul(a, b):
    return 0 if a == 0 or b == 0 else EXP[LOG[a] + LOG[b]]


def syndromes_zero(codewords, n_ec):
    """True when the block, data then check bytes, is a codeword: c(a^i) == 0 for i in 0..n_ec-1."""
    for i in range(n_ec):
        acc = 0
        for c in codewords:
            acc = gf_mul(acc, EXP[i]) ^ c
        if acc:
            return False
    return True


# ---- the standard's tables (level M only) --------------------------------------------------

# version -> (blocks, check bytes per block) at level M
ECC_M = {1: (1, 10), 2: (1, 16), 3: (1, 26), 4: (2, 18), 5: (2, 24), 6: (4, 16), 7: (4, 18),
         8: (4, 22), 9: (5, 22), 10: (5, 26), 11: (5, 30), 12: (8, 22), 13: (9, 22),
         14: (9, 24), 15: (10, 24)}
ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34], 7: [6, 22, 38],
         8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50], 11: [6, 30, 54], 12: [6, 32, 58],
         13: [6, 34, 62], 14: [6, 26, 46, 66], 15: [6, 26, 48, 70]}
ECL_BITS = {0: "M", 1: "L", 2: "H", 3: "Q"}


class QRError(Exception):
    pass


def raw_modules(ver):
    n = (16 * ver + 128) * ver + 64
    if ver >= 2:
        k = ver // 7 + 2
        n -= (25 * k - 10) * k - 55
        if ver >= 7:
            n -= 36
    return n


def format_bits(data5):
    rem = data5
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return ((data5 << 10) | rem) ^ 0x5412


def version_bits(ver):
    rem = ver
    for _ in range(12):
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
    return (ver << 12) | rem


def function_mask(ver):
    size = ver * 4 + 17
    fn = [[False] * size for _ in range(size)]
    for i in range(size):
        fn[6][i] = fn[i][6] = True
    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < size and 0 <= y < size:
                    fn[y][x] = True
    pos = ALIGN[ver]
    for i, py in enumerate(pos):
        for j, px in enumerate(pos):
            if (i == 0 and j == 0) or (i == 0 and j == len(pos) - 1) or (i == len(pos) - 1 and j == 0):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    fn[py + dy][px + dx] = True
    for x, y in format_positions(size)[0] + format_positions(size)[1]:
        fn[y][x] = True
    fn[size - 8][8] = True
    if ver >= 7:
        for i in range(18):
            a, b = size - 11 + i % 3, i // 3
            fn[b][a] = fn[a][b] = True
    return fn


def format_positions(size):
    """(x, y) of format bit 0..14, for the first copy and the second."""
    c1 = [(8, i) for i in range(6)] + [(8, 7), (8, 8), (7, 8)] + [(14 - i, 8) for i in range(9, 15)]
    c2 = [(size - 1 - i, 8) for i in range(8)] + [(8, size - 15 + i) for i in range(8, 15)]
    return c1, c2


def mask_bit(m, x, y):
    return [(x + y) % 2 == 0, y % 2 == 0, x % 3 == 0, (x + y) % 3 == 0,
            (x // 3 + y // 2) % 2 == 0, x * y % 2 + x * y % 3 == 0,
            (x * y % 2 + x * y % 3) % 2 == 0, ((x + y) % 2 + x * y % 3) % 2 == 0][m]


def decode_modules(mod):
    """mod: square list of lists of bool, True = dark, quiet zone already removed."""
    size = len(mod)
    if size < 21 or (size - 17) % 4 or any(len(r) != size for r in mod):
        raise QRError("not a QR symbol: %d x %d modules" % (size, len(mod[0]) if mod else 0))
    ver = (size - 17) // 4
    if ver not in ECC_M:
        raise QRError("version %d is outside what this reads (1 to 15)" % ver)

    # format information, from the first copy, falling back to the second
    best = None
    for copy in format_positions(size):
        got = sum(1 << i for i, (x, y) in enumerate(copy) if mod[y][x])
        for d in range(32):
            dist = bin(got ^ format_bits(d)).count("1")
            if best is None or dist < best[0]:
                best = (dist, d)
        if best[0] <= 3:
            break
    if best[0] > 3:
        raise QRError("the format information is unreadable")
    ecl, mask = ECL_BITS[best[1] >> 3], best[1] & 7
    if ecl != "M":
        raise QRError("error-correction level %s, and this reads level M only" % ecl)

    fn = function_mask(ver)
    bits = []
    right = size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            for j in range(2):
                x = right - j
                y = (size - 1 - vert) if ((right + 1) & 2) == 0 else vert
                if not fn[y][x]:
                    bits.append(mod[y][x] ^ mask_bit(mask, x, y))
        right -= 2
    total = raw_modules(ver) // 8
    if len(bits) < total * 8:
        raise QRError("the symbol holds %d data modules, %d expected" % (len(bits), total * 8))
    cw = [sum(int(bits[i * 8 + k]) << (7 - k) for k in range(8)) for i in range(total)]

    blocks, n_ec = ECC_M[ver]
    data_total = total - blocks * n_ec
    short, n_long = data_total // blocks, data_total % blocks
    lens = [short] * (blocks - n_long) + [short + 1] * n_long
    data_blocks = [[] for _ in range(blocks)]
    ec_blocks = [[] for _ in range(blocks)]
    pos = 0
    for i in range(short + 1):
        for b in range(blocks):
            if i < lens[b]:
                data_blocks[b].append(cw[pos])
                pos += 1
    for _ in range(n_ec):
        for b in range(blocks):
            ec_blocks[b].append(cw[pos])
            pos += 1
    for b in range(blocks):
        if not syndromes_zero(data_blocks[b] + ec_blocks[b], n_ec):
            raise QRError("block %d fails its Reed-Solomon check: the symbol is damaged" % (b + 1))

    stream = "".join(format(c, "08b") for blk in data_blocks for c in blk)
    return read_segments(stream, ver)


ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"


def read_segments(stream, ver):
    """The text of every segment, in order. go-qrcode picks numeric, alphanumeric or byte per run
    of the text, so an otpauth URI arrives in several."""
    out, pos = bytearray(), 0
    while True:
        mode = stream[pos:pos + 4]
        pos += 4
        if len(mode) < 4 or mode == "0000":
            break
        wide = ver >= 10
        if mode == "0100":
            n = int(stream[pos:pos + (16 if wide else 8)], 2)
            pos += 16 if wide else 8
            body = stream[pos:pos + n * 8]
            if len(body) < n * 8:
                raise QRError("a byte segment runs past the data")
            pos += n * 8
            out += bytes(int(body[i:i + 8], 2) for i in range(0, n * 8, 8))
        elif mode == "0010":
            n = int(stream[pos:pos + (11 if wide else 9)], 2)
            pos += 11 if wide else 9
            for _ in range(n // 2):
                v = int(stream[pos:pos + 11], 2)
                pos += 11
                out += (ALNUM[v // 45] + ALNUM[v % 45]).encode()
            if n % 2:
                out += ALNUM[int(stream[pos:pos + 6], 2)].encode()
                pos += 6
        elif mode == "0001":
            n = int(stream[pos:pos + (12 if wide else 10)], 2)
            pos += 12 if wide else 10
            left = n
            while left:
                k = min(3, left)
                width = {3: 10, 2: 7, 1: 4}[k]
                out += str(int(stream[pos:pos + width], 2)).zfill(k).encode()
                pos += width
                left -= k
        else:
            raise QRError("segment mode %s, and this reads numeric, alphanumeric and byte" % mode)
    return bytes(out).decode("utf-8")


# ---- from a picture --------------------------------------------------------------------------

def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise QRError("not a PNG")
    pos, idat, plte = 8, b"", None
    w = h = depth = ctype = interlace = None
    while pos + 8 <= len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        typ, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif typ == b"PLTE":
            plte = body
        elif typ == b"IDAT":
            idat += body
    if w is None or not idat:
        raise QRError("the PNG has no image data")
    if interlace:
        raise QRError("an interlaced PNG")
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    stride = (w * ch * depth + 7) // 8
    bpp = max(1, ch * depth // 8)
    raw = zlib.decompress(idat)
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line

    def dark(x, y):
        line = rows[y]
        if ctype in (0, 3):
            if depth == 8:
                v = line[x]
            else:
                v = (line[x * depth // 8] >> (8 - depth - (x * depth) % 8)) & ((1 << depth) - 1)
            if ctype == 3:
                if plte is None:
                    raise QRError("a palette image with no palette")
                r, g, b = plte[3 * v:3 * v + 3]
                return (r + g + b) / 3 < 128
            return v * 255 // ((1 << depth) - 1) < 128
        return sum(line[x * ch:x * ch + 3]) / 3 < 128 if depth == 8 else False

    return w, h, dark


def decode_png(path, flip=()):
    """flip: (row, column) modules to invert after sampling, which the self-test uses to damage a code."""
    w, h, dark = read_png(path)
    if w != h:
        raise QRError("the picture is %d x %d, not square" % (w, h))
    best = None
    for size in range(21, 21 + 4 * 15, 4):
        real = size + 8          # the symbol with its four-module quiet zone, scaled to the picture
        mpp = real / w

        def at(mx, my, mpp=mpp):
            return dark(min(w - 1, int((mx + 0.5) / mpp)), min(h - 1, int((my + 0.5) / mpp)))

        # a finder pattern is a dark 7 x 7 ring round a dark 3 x 3 block, with a light ring between
        score = 0
        for cx, cy in ((4, 4), (4 + size - 7, 4), (4, 4 + size - 7)):
            for dy in range(7):
                for dx in range(7):
                    ring = max(abs(dx - 3), abs(dy - 3))
                    want = ring != 2
                    score += at(cx + dx, cy + dy) == want
        if best is None or score > best[0]:
            best = (score, size, at)
    score, size, at = best
    if score < 3 * 49 * 0.9:
        raise QRError("no QR finder patterns in the picture (best fit %d of %d)" % (score, 3 * 49))
    mod = [[at(4 + x, 4 + y) for x in range(size)] for y in range(size)]
    for r, c in flip:
        mod[r][c] = not mod[r][c]
    return decode_modules(mod)


def decode_art(text):
    """The half-block text; the longest run of lines of art glyphs, each two spaces in, is the code."""
    glyphs = " █▀▄"
    runs, cur = [], []
    for line in text.splitlines():
        body = line[2:] if line.startswith("  ") else None
        if body and len(body) >= 29 and all(ch in glyphs for ch in body) and body.strip(" ") != "":
            cur.append(body)
        else:
            if cur:
                runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)
    if not runs:
        raise QRError("no QR block in the output")
    rows = max(runs, key=len)
    width = len(rows[0])
    if any(len(r) != width for r in rows):
        raise QRError("the block's lines are not all the same width")
    grid = []
    for k, line in enumerate(rows):
        last = k == len(rows) - 1 and (width % 2 == 1)  # an odd count of module rows ends on a half row
        upper, lower = [], []
        for ch in line:
            if ch == " ":
                upper.append(True); lower.append(True)       # both dark
            elif ch == "█":
                upper.append(False); lower.append(False)     # both light
            elif ch == "▄":
                upper.append(True); lower.append(False)
            else:
                upper.append(False); lower.append(True)
        grid.append(upper)
        if not last:
            grid.append(lower)
    size = width - 8
    if len(grid) != width:
        raise QRError("a block %d wide and %d module rows tall is not a square symbol" % (width, len(grid)))
    return decode_modules([row[4:4 + size] for row in grid[4:4 + size]])


# ---- the self-test: a code built here, so the reader is not tested against its own blind spots -

def _selftest():
    # Built from the standard, independently of the reader above: place a known byte string
    # at version 1, level M, mask 0, by encoding it (data, Reed-Solomon, function patterns).
    text = "selftest-1"
    ver, size = 1, 21
    bitstr = "0100" + format(len(text), "08b") + "".join(format(b, "08b") for b in text.encode())
    bitstr += "0000"
    bitstr += "0" * (-len(bitstr) % 8)
    cwords = [int(bitstr[i:i + 8], 2) for i in range(0, len(bitstr), 8)]
    pad = [0xEC, 0x11]
    while len(cwords) < 16:
        cwords.append(pad[(len(cwords) - len(bitstr) // 8) % 2])
    # generator polynomial for 10 check bytes
    gen = [1]
    for i in range(10):
        nxt = [0] * (len(gen) + 1)
        for j, g in enumerate(gen):
            nxt[j] ^= g
            nxt[j + 1] ^= gf_mul(g, EXP[i])
        gen = nxt
    rem = [0] * 10
    for b in cwords:
        f = b ^ rem[0]
        rem = rem[1:] + [0]
        for j in range(10):
            rem[j] ^= gf_mul(gen[j + 1], f)
    allcw = cwords + rem
    bits = [(c >> (7 - k)) & 1 for c in allcw for k in range(8)]
    mod = [[False] * size for _ in range(size)]
    fn = function_mask(ver)
    i, right = 0, size - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(size):
            for j in range(2):
                x = right - j
                y = (size - 1 - vert) if ((right + 1) & 2) == 0 else vert
                if not fn[y][x]:
                    bit = bits[i] if i < len(bits) else 0
                    mod[y][x] = bool(bit) ^ mask_bit(0, x, y)
                    i += 1
        right -= 2
    fb = format_bits((0 << 3) | 0)          # level M, mask 0
    for copy in format_positions(size):
        for k, (x, y) in enumerate(copy):
            mod[y][x] = bool((fb >> k) & 1)
    mod[size - 8][8] = True
    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-3, 4):
            for dx in range(-3, 4):
                x, y = cx + dx, cy + dy
                if 0 <= x < size and 0 <= y < size:
                    mod[y][x] = max(abs(dx), abs(dy)) != 2 and max(abs(dx), abs(dy)) != 4
    for k in range(8, size - 8):
        mod[6][k] = mod[k][6] = (k % 2 == 0)
    got = decode_modules(mod)
    assert got == text, "read %r, built %r" % (got, text)
    mod[10][10] = not mod[10][10]
    mod[12][14] = not mod[12][14]
    try:
        decode_modules(mod)
    except QRError:
        pass
    else:
        raise AssertionError("a damaged symbol was read without complaint")
    print("selftest ok")


def main(argv):
    try:
        if len(argv) == 2 and argv[1] == "selftest":
            _selftest()
            return 0
        if len(argv) == 3 and argv[1] == "png":
            print(decode_png(argv[2]))
            return 0
        if len(argv) == 3 and argv[1] == "art":
            print(decode_art(open(argv[2], encoding="utf-8").read()))
            return 0
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    except QRError as e:
        print("qr_decode: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
