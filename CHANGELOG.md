# Changelog

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
