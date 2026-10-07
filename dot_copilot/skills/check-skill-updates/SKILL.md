---
name: check-skill-updates
description: Check whether locally adapted personal Copilot skills have changed upstream without overwriting local customizations. Use when the user says "check skill updates", "are my skills up to date", "update my Copilot skills", "check upstream skills", or asks whether newer skill versions exist.
metadata:
  x-origin: "local"
  x-update-command: "check-copilot-skill-updates"
---

# Check Skill Updates

Run:

```bash
check-copilot-skill-updates
```

Interpret the result:

- Exit `0`: all automatically tracked upstream files match their recorded hashes.
- Exit `1`: one or more upstream skills changed. This is an update result, not a command failure.
- Exit `2`: the check could not complete because of configuration, network, or fetch errors.
- `MANUAL`: the source cannot be checked automatically; report its recorded source and version.

If updates exist:

1. Report the affected skills and upstream URLs.
2. Do not replace local files automatically.
3. Offer to compare each upstream change against the local adaptation metadata and merge only
   improvements that preserve the user's custom workflow.

Keep the response concise when everything is current.
