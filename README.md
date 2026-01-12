## CamOrder Workflow (Quick Start)

1) Open `CAMORDER PRO v1.html` in Chrome.
2) Click **Choose Project Folder** and select your project folder.
3) Enable MIDI + Camera, arm the recorder, and record your takes.
4) Click **Export Resolve Package** (this writes:
   - `media/*.webm`
   - `media/camorder-stacked-mov.fcpxml`
   - `convert-to-mov.sh`
)

### Convert WebM -> MOV
5) In Finder, right‑click the **project folder** → **New Terminal at Folder**.
6) Run:

sh convert-to-mov.sh

(This creates `.mov` files and deletes the original `.webm`.)

### Import into DaVinci Resolve
7) Open Resolve and create/open a project.
8) Import media:
- **File → Import → Media…** (Command+I)
- Select the `media` folder and import the `.mov` files.
9) Import the FCPXML:
- **File → Import → Timeline → Import AAF/EDL/XML…** (Shift+Command+I)
- Choose `media/camorder-stacked-mov.fcpxml`
10) If Resolve can’t find clips:
- Add your project folder to **Media Storage**, then re‑import the FCPXML.
