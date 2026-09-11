# Typography assets

Noto Sans Regular and Bold are unmodified static TrueType fonts, distributed under the SIL Open Font License 1.1. Preserve [OFL.txt](OFL.txt) when redistributing these files.

Downloaded on 2026-09-10 from the official archived [notofonts/noto-fonts](https://github.com/notofonts/noto-fonts) repository:

- [NotoSans-Regular.ttf](https://raw.githubusercontent.com/notofonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf)
- [NotoSans-Bold.ttf](https://raw.githubusercontent.com/notofonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Bold.ttf)
- [License](https://raw.githubusercontent.com/notofonts/noto-fonts/main/LICENSE)

| File | SHA-256 |
| --- | --- |
| NotoSans-Regular.ttf | `b85c38ecea8a7cfb39c24e395a4007474fa5a4fc864f6ee33309eb4948d232d5` |
| NotoSans-Bold.ttf | `c976e4b1b99edc88775377fcc21692ca4bfa46b6d6ca6522bfda505b28ff9d6a` |
| OFL.txt | `0dab92d0544f7b233403f14b84a663bdbfa746982eda629e7f4f9ffe1b036feb` |

`body.font` uses Regular at 24 px and `heading.font` uses Bold at 40 px. Both use distance fields with Defold's matching `font-df.material`. The debug render messages use Defold's built-in Vera Mono Bold font; it is not replaceable through a project font resource. Release statistics use the normal GUI font.

The resource character sets include printable ASCII, the complete Russian alphabet including Ё/ё, and punctuation used by the interface. Unused outlines and shadows are disabled; Defold sizes the glyph caches automatically. Font resource fields follow the [Defold font manual](https://defold.com/manuals/font/) and [FontDesc schema](https://github.com/defold/defold/blob/dev/engine/render/proto/render/font_ddf.proto).
