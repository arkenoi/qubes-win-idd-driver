# Shared by pre-commit and pre-push: list an archive's member names.
# $1 = original path (for extension), $2 = file holding the data. Empty output if unreadable.
archive_members() {
  case "$1" in
    *.zip)
      python3 - "$2" <<'PY' 2>/dev/null
import sys, zipfile
try:
    print('\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))
except Exception:
    pass
PY
      ;;
    *) tar -tf "$2" 2>/dev/null ;;
  esac
}

# The capture-class signature. Content criterion, not a name criterion: whole-desktop
# captures are screen.png / *fullshot* members whatever the archive is called.
CAPTURE_RE='(^|/)screen\.png$|fullshot'
