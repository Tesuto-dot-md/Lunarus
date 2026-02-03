# If you see <<<<<<< HEAD / ======= / >>>>>>> in Dart files

Those are **git merge conflict markers** and Flutter/Dart will not compile while they exist.

## Quick fix (recommended)
1) **Delete your existing project folder** (or move it aside)
2) Extract the provided archive into an empty directory.

This avoids mixing two versions of the same files.

## If you must fix in-place
From the project root:

```bash
# list all files that still contain conflict markers
grep -R -n "<<<<<<<\|=======\|>>>>>>>" client_flutter/lib | head -200

# open each file and keep only one side of the conflict,
# removing the marker lines.
```

After cleanup:

```bash
cd client_flutter
flutter clean
flutter pub get
flutter run -d linux
```
