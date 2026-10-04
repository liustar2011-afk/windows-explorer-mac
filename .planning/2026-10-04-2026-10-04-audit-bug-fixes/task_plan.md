# Audit bug fixes

Scope: all 14 reported correctness bugs fixed; pre-existing changes preserved.

1. Complete: transactional/cancellable transfers, metadata/symlink preservation, destination validation (including directory aliases).
2. Complete: modal mouse/keyboard isolation; tab identity, search generations and transfer selection; snapshot-based undo/redo; batch rename rollback.
3. Complete: comparison generations and folder-pair binding; rootmost nested sync planning and safe replacement; whitespace-preserving archive parsing.
4. Complete: 176 selftests passed, including real cross-volume 128 MB cancellation. Built and signed, installed to /Applications/File Explorer.app, verified matching binary hashes and relaunched.
