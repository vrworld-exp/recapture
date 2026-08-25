# fastlane/secrets/

This directory holds credentials required by Fastlane lanes.
**All credential files in this directory are gitignored and must never be committed.**

Obtain these files from the team password manager (Bitwarden / 1Password).

## Files expected here

### play-store-service-account.json
- Required by: `fastlane android internal` lane
- How to obtain:
  1. Google Play Console → Setup → API access
  2. Link to a Google Cloud project
  3. Create a service account with "Release manager" role (not just viewer)
  4. Download JSON key
  5. Save as `fastlane/secrets/play-store-service-account.json`
- Note: The app must exist on Play Console and have at least one manual APK/AAB
  upload before the API can upload subsequent versions. First upload must be done
  manually via the Play Console web UI.

### match_env (future — iOS only)
- Required by: `fastlane ios build` and `fastlane ios testflight` lanes
- Created when iOS activation checklist is complete
- Contains MATCH_PASSWORD for decrypting the certificates repository
