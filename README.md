# osu! Companion for iOS

Unofficial SwiftUI port of [maidkedi/osu-companion](https://github.com/maidkedi/osu-companion) (Android). MIT-licensed upstream; osu! is a trademark of ppy Pty Ltd.

## Install

Grab `OsuCompanion.ipa` from the [latest release](../../releases/latest) and sideload it (FlareStore, AltStore, Sideloadly). The IPA is unsigned; your sideloader signs it.

## Included

- osu! OAuth2 + PKCE sign-in (token exchange via the Cloudflare Worker proxy, no secret in the app)
- Your profile, top and recent scores (Lazer / Classic `CL` labelled)
- Player lookup, global and country rankings for all 4 rulesets
- Beatmap search with mirror download links
- Friends list
- Settings for OAuth client ID, proxy URL and redirect URI

## Not ported yet

Bancho IRC chat, referee tools, rosu-pp simulator, widgets, score cards, background alerts.

## Sign-in note

The app uses redirect `osuchat://oauth/callback`. The osu! OAuth app must have that callback registered. If login fails with a redirect error, register your own osu! OAuth app + Worker (see upstream `worker/README.md`) and enter them in Settings.

## Build

Push to `main`; GitHub Actions builds the IPA on a macOS runner. Locally: `brew install xcodegen && xcodegen generate`, then open the project in Xcode.
