# OpenLeash Mobile Client 📱⚡

[![Flutter](https://img.shields.io/badge/flutter-mobile-02569b)](#)
[![iOS](https://img.shields.io/badge/ios-supported-111718)](#)
[![Android](https://img.shields.io/badge/android-supported-3ddc84)](#)

The iOS/Android companion app for approving OpenLeash decisions away from the desktop.

## What It Does

- Discovers an organization's managed API
- Signs existing users in with OAuth / SSO
- Registers the phone for approval workflows
- Shows pending decisions
- Sends allow/deny responses back to the API

Mobile is sign-in only. Create the OpenLeash account from desktop or the web, then use the phone as the approval companion.

## Run

Start the local public-cloud dev stack first:

```bash
./run.py --mode public-cloud --clean-slate
```

```bash
cd apps/mobile-client
flutter pub get
flutter run
```

iOS simulator against the local public-cloud API:

```bash
flutter run -d ios \
  --dart-define=OPENLEASH_CLOUD_API_URL=http://localhost:9318 \
  --dart-define=OPENLEASH_DASHBOARD_URL=http://localhost:9302
```

Android emulator against the local public-cloud API:

```bash
flutter run -d android \
  --dart-define=OPENLEASH_CLOUD_API_URL=http://10.0.2.2:9318 \
  --dart-define=OPENLEASH_DASHBOARD_URL=http://10.0.2.2:9302
```

## Local API Tips

- iOS Simulator can usually reach `http://localhost:9318`.
- Android Emulator may need `http://10.0.2.2:9318`.
- Physical devices need your laptop's LAN IP.
- Managed private-cloud and OpenLeash Cloud discover identity from the API.
- `./run.py --real-oauth` works cleanly on iOS Simulator with a localhost OAuth redirect. Android Emulator real OAuth also needs the matching `10.0.2.2` redirect URI registered with the identity provider; otherwise use the default local dev-auth shortcut for Android dev.

## UX Rule

Approvals should be fast, readable, and hard to misunderstand. The mobile app is not where users debug policy theory; it is where they make a crisp allow/deny decision.
