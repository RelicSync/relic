"""Carry installed dependency notices into the redistributed worker bundle."""
import importlib.metadata
from pathlib import Path
import shutil
import sys

destination = Path(sys.argv[1]) / 'licenses'
destination.mkdir(parents=True, exist_ok=True)
for distribution in importlib.metadata.distributions():
    name = distribution.metadata['Name']
    for file in distribution.files or []:
        if any(marker in Path(str(file)).name.lower() for marker in ('license', 'copying', 'notice')):
            source = distribution.locate_file(file)
            if source.is_file():
                target = destination / name / str(file).replace('../', '').replace('..\\', '')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
python_license = Path(sys.base_prefix) / 'LICENSE.txt'
if python_license.exists():
    shutil.copyfile(python_license, destination / 'Python-LICENSE.txt')
