# Changelog

### v1.3
- Added Azure idle resource report (Python) to the toolkit
- Updated Invoke-M365Toolkit.ps1 with menu option 5 and RunPython helper
- Idle report includes cost attribution, AKS review bucket, remediation hints, and JSON/CSV output

## v1.2 – Onboarding refactor
- Switched to direct Microsoft Graph API calls for user creation
- Fixed password profile serialization issues
- Implemented reliable license assignment via assignLicense endpoint
- Enforced mandatory JobTitle
- Added preflight validation and debug logging