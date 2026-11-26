# Changelog

## 1.0.1

The built-in CSV, JSON and YAML conversions follow the same rules as the other editors' plugins.

- CSV: a repeated header becomes `name_2` and an empty one `column3` (they were `name (2)` and
  `column 3`), each checked against every other name; the separator is the one the first line uses
  most outside quotes: comma, semicolon, tab or `|` (only commas were read before).
- JSON to YAML: an empty list or object is written `[]` or `{}`; it was an empty document, which
  YAML reads as null. The C1 controls and the line and paragraph separators are escaped; text
  beyond ASCII is no longer quoted.
- JSON to CSV: lines end in CRLF, as RFC 4180 writes them (they ended in LF); an empty list says
  there is nothing to write.
- JSON numbers that JSON does not allow (`01`, `1.`) are refused.
- The four editor plugins (VS Code, JetBrains, Sublime Text, Neovim) now follow the same rules and run the same test cases, so a file gives the same result in each.

## 1.0.0

First release.

- `:ConverterStudio {format}` converts the current file; `:ConverterStudio` lists the formats it can
  become and where each one runs.
- On this computer: built-in CSV, JSON and YAML conversions and SRT ↔ WebVTT; FFmpeg, LibreOffice,
  Pandoc, ImageMagick, Ghostscript and Tesseract when installed, each asked what it can do. Results
  are saved next to the original and never replace a file.
- The Converter Studio desktop app (0.1.11 or later), when turned on, for formats nothing on this
  computer converts.
- The cloud at converter.studio only when chosen (`:ConverterStudio cloud {format}`), with an API key
  from the environment or `setup()`; asks before a conversion above `cloud.max_credits`.
- `:ConverterStudio cancel`, a time limit for programs, `:checkhealth converter-studio` and
  `:help converter-studio`.
