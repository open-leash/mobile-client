# OpenLeash Mobile Client 📱⚡

[![Flutter](https://img.shields.io/badge/flutter-mobile-02569b)](#)
[![iOS](https://img.shields.io/badge/ios-supported-111718)](#)
[![Android](https://img.shields.io/badge/android-supported-3ddc84)](#)

The iOS/Android companion app for approving OpenLeash decisions away from the desktop.

## What It Does

- Discovers an organization's managed API
- Signs users in with OAuth / SSO
- Registers the phone for approval workflows
- Shows pending decisions
- Sends allow/deny responses back to the API

## Run

```bash
cd apps/mobile-client
flutter pub get
flutter run
```

iOS:

```bash
flutter run -d ios
```

Android:

```bash
flutter run -d android
```

## Local API Tips

- iOS Simulator can usually reach `http://localhost:9318`.
- Android Emulator may need `http://10.0.2.2:9318`.
- Physical devices need your laptop's LAN IP.
- Managed private-cloud and OpenLeash Cloud discover identity from the API.

## UX Rule

Approvals should be fast, readable, and hard to misunderstand. The mobile app is not where users debug policy theory; it is where they make a crisp allow/deny decision.
