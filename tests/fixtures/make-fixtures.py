#!/usr/bin/env python3
"""Write minimal, valid .docx, .xlsx and .pptx files for the handler tests."""
import sys
import zipfile
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent)
RELS = ('<?xml version="1.0" encoding="UTF-8"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="{part}"/>'
        '</Relationships>')
TYPES = ('<?xml version="1.0" encoding="UTF-8"?>'
         '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
         '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
         '<Default Extension="xml" ContentType="application/xml"/>'
         '<Override PartName="/{part}" ContentType="{ctype}"/></Types>')
DOCS = {
    "test.docx": ("word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
                  '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>omarchohard</w:t></w:r></w:p></w:body></w:document>'),
    "test.xlsx": ("xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
                  '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets/></workbook>'),
    "test.pptx": ("ppt/presentation.xml", "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
                  '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>'),
}
OUT.mkdir(parents=True, exist_ok=True)
for name, (part, ctype, body) in DOCS.items():
    with zipfile.ZipFile(OUT / name, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", TYPES.format(part=part, ctype=ctype))
        z.writestr("_rels/.rels", RELS.format(part=part))
        z.writestr(part, body)
    print(OUT / name)
