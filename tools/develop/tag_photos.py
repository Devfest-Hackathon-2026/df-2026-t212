"""Turn generated PNGs into JPEGs with a capture date and GPS, like real phone photos.

.venv/bin/python tag_photos.py gen out_dir
"""
import sys
from pathlib import Path

from PIL import Image

# name prefix -> (lat, lng, taken)
META = {
    "01": (35.7111, 139.7964, "2026:01:03 11:24:10"),  # Asakusa
    "02": (35.6930, 139.6995, "2026:02:11 19:02:44"),  # Shinjuku alley
    "03": (35.6560, 139.7480, "2025:12:02 14:31:05"),  # Shiba Park
    "04": (35.6997, 139.7650, "2026:03:08 08:12:37"),  # Ochanomizu
    "05": (35.7107, 139.7745, "2026:01:20 15:48:19"),  # Ueno
    "06": (35.6595, 139.7005, "2026:02:02 17:20:51"),  # Shibuya
    "07": (35.6745, 139.7180, "2025:12:05 10:06:33"),  # Gaien
    "08": (35.7262, 139.7710, "2026:04:14 13:55:02"),  # Nezu
    "09": (35.6486, 139.7031, "2026:06:10 16:40:28"),  # Ebisu
    "10": (35.6812, 139.7988, "2026:03:21 10:27:45"),  # Kiyosumi
    "11": (35.6717, 139.7650, "2026:05:09 18:33:12"),  # Ginza
    "12": (35.6820, 139.7930, "2026:07:18 12:14:56"),  # Sumida river
    "13": (35.7266, 139.7690, "2026:08:03 19:08:21"),  # Yanaka
    "14": (35.7210, 139.7520, "2026:06:18 09:42:09"),  # Hakusan
    "15": (35.7029, 139.8251, "2026:04:28 11:16:38"),  # Kameido
    "16": (35.6440, 139.6980, "2026:03:30 14:02:17"),  # Meguro river
}


def rational(v):
    v = abs(v)
    d = int(v)
    m = int((v - d) * 60)
    s = ((v - d) * 60 - m) * 60
    return (float(d), float(m), round(s, 2))


def main(src, dst):
    dst = Path(dst)
    dst.mkdir(parents=True, exist_ok=True)
    for p in sorted(Path(src).glob("*.png")):
        lat, lng, t = META[p.name[:2]]
        im = Image.open(p).convert("RGB")
        ex = im.getexif()
        ex[0x010F] = "Apple"
        ex[0x0110] = "iPhone 17 Pro"
        ex[0x0132] = t
        e = ex.get_ifd(0x8769)
        e[0x9003] = t
        e[0x9004] = t
        g = ex.get_ifd(0x8825)
        g.update({1: "N", 2: rational(lat), 3: "E", 4: rational(lng)})
        out = dst / (p.stem + ".jpg")
        im.save(out, "JPEG", quality=90, exif=ex)
        print(out.name, t, lat, lng)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
