# Plan
1. Inspect source and preserve existing column-resize edits — complete
2. Add persistent system/Chinese/English language selection and localize UI — complete
3. Refine surfaces, typography, selection and toolbar spacing — complete
4. Build, run self-tests in both languages, inspect snapshots — complete

Final validation: English 106/106, Chinese 106/106; seven window captures inspected; narrow header clipping fixed and recaptured; plist/resources lint and ad-hoc signature verification passed; git diff whitespace check passed.

5. Add optional alternating Details row backgrounds, verify and update installed app — complete

6. External open/reveal and default folder integration UI — implemented, tested and installed. Automatic folder association is blocked by macOS 27.0 returning OSStatus -50; Finder remains default.
