# converter-studio.nvim

A file converter for Neovim. `:ConverterStudio webp` turns the image you are editing into WebP,
`:ConverterStudio pdf` a Word document into PDF, `:ConverterStudio mp3` a video into MP3, and
`:ConverterStudio` lists every format the file can become and where each conversion runs.

Conversions run **on your computer first**: built-in Lua conversions and the programs you already
have (FFmpeg, LibreOffice, Pandoc, ImageMagick, Ghostscript, Tesseract). For anything else you can
hand the file to the [Converter Studio](https://converter.studio) desktop app, or, when you choose
it, convert it online at converter.studio.

Example: `:ConverterStudio` on an iPhone photo, with ImageMagick installed (the list comes from
`vim.ui.select`, so a picker plugin shows it in its own window):

```text
Convert IMG_0412.heic to
1: JPG            on this computer (ImageMagick)
2: PNG            on this computer (ImageMagick)
3: WebP           on this computer (ImageMagick)
4: AVIF           on this computer (ImageMagick)
5: GIF            on this computer (ImageMagick)
6: TIFF           on this computer (ImageMagick)
7: BMP            on this computer (ImageMagick)
8: ICO            on this computer (ImageMagick)
9: PDF            on this computer (ImageMagick)
10: In the cloud…  uploads the file to converter.studio, uses credits
```

Choosing JPG writes `IMG_0412.jpg` next to the photo and says so:
`Converter Studio: IMG_0412.heic → IMG_0412.jpg (on this computer, ImageMagick)`.

## Where conversions run

| Where                                                                 | When                                                                     | Your file                                                                      |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| **On this computer**                                                  | Always first: built in, or with a program that is installed              | Stays on your computer                                                         |
| **[Converter Studio desktop app](https://converter.studio/download)** | Only if you turn it on, for formats nothing on this computer converts    | Stays on your computer; the app shows it, you press Convert                    |
| **The cloud** (converter.studio)                                      | Only when you choose it: `:ConverterStudio cloud <format>` or the picker | Uploaded to converter.studio, converted, deleted; uses credits of your account |

A conversion that fails on your computer is never sent to the cloud by itself: the plugin asks
first ("Try in the cloud (uploads photo.heic to converter.studio, uses credits)"). Results are saved
next to the original and never replace a file: when `photo.webp` exists, the result is
`photo (2).webp`.

## What it converts on your computer

| With               | Converts                                                                                                                                                             |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Nothing (built in) | CSV to JSON or YAML, JSON to CSV or YAML, SRT subtitles to WebVTT and back                                                                                           |
| FFmpeg             | Video to MP4, WebM, MOV, MKV or GIF; video and audio to MP3, M4A, WAV, FLAC, OGG, Opus, AAC or AIFF; animated GIF to MP4                                             |
| LibreOffice        | Word, Excel, PowerPoint and OpenDocument files to PDF and to each other (DOCX, DOC, ODT, RTF, XLSX, XLS, ODS, CSV, PPTX, PPT, ODP); HTML to PDF                      |
| Pandoc             | Markdown, HTML, DOCX, ODT, EPUB, RTF and FB2 to each other and to plain text; to PDF when a PDF engine (typst, a LaTeX engine, weasyprint, wkhtmltopdf) is installed |
| ImageMagick        | JPG, PNG, WebP, HEIC, AVIF, GIF, BMP, TIFF, ICO and SVG to JPG, PNG, WebP, AVIF, GIF, TIFF, BMP, ICO or PDF                                                          |
| Ghostscript        | A smaller PDF (`report-compressed.pdf`); EPS to PDF                                                                                                                  |
| Tesseract          | Text recognition (OCR) of images to text, or to a searchable PDF                                                                                                     |

The plugin asks each program what it can do instead of assuming it: an ImageMagick without HEIC
support or an FFmpeg without a VP9 encoder simply offers fewer formats. `:checkhealth
converter-studio` shows what was found. Programs run with an argument list (never through a
shell), with a time limit, and stop with `:ConverterStudio cancel` or when you quit Neovim.

## Requirements

- Neovim 0.10 or later. No other plugin.
- Any of the programs above, on your `PATH` or in their usual install folders (Homebrew, Program
  Files, Snap, Flatpak…). None is required: the built-in conversions always work.
- For the desktop app: [Converter Studio for desktop](https://converter.studio/download) 0.1.11 or
  later.
- For the cloud: `curl` and a [Converter Studio](https://converter.studio) API key.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'tariksucu/converter-studio.nvim',
  cmd = 'ConverterStudio',
  opts = {},
}
```

Neovim 0.12's built-in `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/tariksucu/converter-studio.nvim' })
```

Or clone it into a `pack/*/start` folder. `setup()` is optional; nothing loads until you use the
command.

## Usage

| Command                             | What it does                                                                                   |
| ----------------------------------- | ---------------------------------------------------------------------------------------------- |
| `:ConverterStudio`                  | Lists the formats the current file can become and where each one runs; "In the cloud…" is last |
| `:ConverterStudio {format}`         | Converts on your computer (or with the desktop app, if turned on): `webp`, `pdf`, `mp3`, `md`… |
| `:ConverterStudio cloud [{format}]` | Converts at converter.studio (uploads the file, uses credits)                                  |
| `:ConverterStudio desktop {format}` | Hands the file to the Converter Studio desktop app                                             |
| `:ConverterStudio cancel`           | Stops the conversions that are running                                                         |

Press <kbd>Tab</kbd> after `:ConverterStudio ` for the formats of the current file. The picker uses
`vim.ui.select`, so it shows up in your picker plugin if you have one. To map it:

```lua
vim.keymap.set('n', '<leader>cc', '<Plug>(converter-studio)')
```

From a file explorer or your own mappings, convert any file:

```lua
require('converter-studio').convert({ file = path, to = 'webp' })
```

## Configuration

The defaults (see `:help converter-studio-setup`):

```lua
require('converter-studio').setup({
  -- Programs by name: a path, or false to never use one
  -- (ffmpeg, soffice, pandoc, magick, gs, tesseract).
  tools = {},
  timeout = 1800, -- seconds a conversion on your computer may run
  ocr_language = nil, -- Tesseract's languages, e.g. 'eng+deu'
  desktop = {
    enabled = false, -- use the Converter Studio desktop app when installed
  },
  cloud = {
    api_key = nil, -- a string or a function; default: $CONVERTER_STUDIO_API_KEY
    api_url = 'https://converter.studio/api',
    max_credits = 20, -- a cloud conversion that costs more asks first (0: always ask)
  },
})
```

## The desktop app

With `desktop = { enabled = true }`, formats that nothing on your computer converts are handed to
the [Converter Studio desktop app](https://converter.studio/download) (version 0.1.11 or later):
the app asks whether to take the file from Neovim, then shows it in its Convert tab with the format
chosen, and converts it on your computer when you press Convert. Nothing is uploaded. The hand-off
is not used when Neovim runs over SSH or inside WSL (the file is not on the computer where the app
runs), and the Snap and Flatpak builds of the app only see files in your home folder.

## The cloud

1. Make a free account at [converter.studio](https://converter.studio) and an API key on your
   [account page](https://converter.studio/account#api-keys).
2. Set the environment variable `CONVERTER_STUDIO_API_KEY`, or give `cloud.api_key` to `setup()`
   (a function can read it from your password manager). The plugin never writes the key anywhere.
3. Run `:ConverterStudio cloud webp`, or pick "In the cloud…".

Each conversion uses credits of your account: most image and document conversions cost 1 credit,
video and audio cost more depending on their length. A free account gets free credits every day;
[paid plans](https://converter.studio/pricing) have more credits and larger files. A conversion that
costs more than `max_credits` asks first, and a failed conversion costs nothing. The cloud adds
what your computer may not have: HEIC and camera RAW photos, e-books (MOBI, AZW3), fonts, archives,
text recognition of PDFs and more; the API is documented at
[converter.studio/developers](https://converter.studio/developers).

## Privacy

- On your computer and with the desktop app, files stay on your computer.
- In the cloud, the file is sent to converter.studio over HTTPS, converted and deleted: the upload
  right after the conversion, the result after 6 hours. Requests name the plugin and its version
  (`X-Converter-Studio-Client`) so Converter Studio can count conversions by integration.
- The API key is passed to `curl` on its standard input, never on its command line, and never
  appears in a message.
- The public list of formats (no file, no key) is read when you open the cloud list or use the
  desktop app, and kept for a day in Neovim's cache folder.
- No telemetry. See the [privacy policy](https://converter.studio/privacy).

## Health check

`:checkhealth converter-studio` lists the programs found and what each one adds, whether the
desktop app is set up, and where the API key comes from (never the key itself).

## Contributing

Issues and pull requests are welcome. Before sending a change:

```sh
make test   # mini.test in headless Neovim (clones mini.test into deps/)
make lint   # stylua --check and luacheck
```

The tests convert real files with the programs that are installed (a test whose program is missing
is skipped) and test the cloud against a small fake API on 127.0.0.1, with no network.

## License

[MIT](LICENSE), © Converter Studio. Questions and bug reports:
[GitHub issues](https://github.com/tariksucu/converter-studio.nvim/issues) or
support@converter.studio.
