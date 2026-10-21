# Pulls

Pulls is a native macOS menu-bar app for GitHub pull requests. This phase connects a GitHub account, lets you choose an allowlist of repositories, and asks for system notification permission only if you want it.

The inbox still shows built-in sample pull requests. Pulls does not sync real pull requests yet.

## Requirements

- macOS 14 or later
- Swift 6.4 or later, installed with Xcode or the Command Line Tools

The app is built with Swift Package Manager. It does not need an Xcode project.

## Register a GitHub OAuth App

Do this before trying to sign in. Pulls uses the OAuth device flow, so there is no backend and no browser window inside the app.

1. Open GitHub **Settings → Developer settings → OAuth Apps → New OAuth App**.
2. Application name: `Pulls` (or another name you will recognize).
3. Homepage URL: `http://127.0.0.1`
4. Authorization callback URL: `http://127.0.0.1/callback`

   GitHub requires a callback URL. The device flow never calls it. Leave wildcard matching off, and do not run a local server.
5. Enable **Device Flow**. If this is off, GitHub returns `device_flow_disabled` and Pulls cannot sign you in.
6. Leave **Expire user access tokens** enabled. New OAuth Apps issue an access token that expires after 8 hours and a refresh token that lasts about 6 months.
7. Register the application.
8. Copy the **Client ID** only.

Do not copy the client secret into Pulls, this repository, your shell history, or the config file. The device flow does not use a client secret. Pulls refuses to send one.

### Permissions Pulls requests

The sign-in request uses this scope string:

```text
repo notifications read:user
```

Pulls does not request `offline_access`. When token expiration is enabled on the OAuth App, GitHub already returns a refresh token. When expiration is off, GitHub returns a non-expiring access token and Pulls keeps that token until GitHub rejects it.

| Scope | What GitHub allows | What Pulls uses it for |
| --- | --- | --- |
| `repo` | Full control of public and private repositories, including code, issues, pull requests, and some organization resources. This is the only OAuth App scope that can list private repositories. There is no read-only private-repository scope. | List repositories you can access, including private ones. A later phase will read pull requests. Pulls does not push or edit anything. |
| `notifications` | Read your notification inbox. The same scope can mark threads read and change subscriptions. | Reserved for a later phase. Pulls does not call the notifications API yet. |
| `read:user` | Read your profile. | Show which GitHub account is connected. |

The Connect step explains this breadth before you authorize.

## Configure the client ID

The client ID is public by OAuth's design, but it is still your app's identifier, so it stays out of git.

```bash
cp Config/GitHubOAuth.example.json Config/GitHubOAuth.json
```

Edit `Config/GitHubOAuth.json`:

```json
{
  "clientId": "Iv1.your-client-id"
}
```

`Config/GitHubOAuth.json` is gitignored. `scripts/build-app.sh` copies it into `Pulls.app` when the file exists. Rebuild after changing it.

Pulls looks for a client ID in this order:

1. The `PULLS_GITHUB_CLIENT_ID` environment variable.
2. `GitHubOAuth.json` inside the app bundle (the copy made at build time).
3. `~/Library/Application Support/app.pulls.macos/github-oauth.json`

An empty or missing ID does not crash the app. The Connect step explains where to put it.

If a config file contains `clientSecret` or `client_secret`, Pulls ignores the value, does not send it, and tells you to remove it.

## Token storage and refresh

GitHub's OAuth documentation says `client_secret` is required when refreshing an access token **unless the token was created with the device flow**. Pulls relies on that exception. A refresh request sends only:

- `client_id`
- `grant_type=refresh_token`
- `refresh_token`

Pulls never stores or transmits a client secret, including an empty one. It does not use a backend to hide a secret. If GitHub rejects the refresh because a client secret is required, Pulls keeps a still-valid access token and, once that token stops working, asks you to connect again.

Using a refresh token rotates it. GitHub invalidates the previous access token and refresh token. Pulls writes the new pair to the Keychain immediately.

The Keychain item is a generic password for this Mac only (`app.pulls.macos` / `github.oauth.credential`), available after first unlock. macOS may ask once for Keychain access. The login, display name, and repository allowlist are not secrets; they are stored in preferences for the `app.pulls.macos` suite. Signing out deletes the Keychain item and leaves that account's allowlist in place, so the same GitHub user does not have to choose repositories again. A different account has its own allowlist.

Pulls logs sign-in progress only. It does not log access tokens, refresh tokens, device codes, or user codes.

## Repository allowlist

The repositories you check are an allowlist, not a subscription to every event in those repositories. A later sync may look at the selected repositories and should notify you only about pull requests that involve you: pull requests you authored, review requests, reviews, and comments where you are a participant. Issues, CI mail, and other repository events are not the product.

A selected repository that disappears from a later successful fetch stays selected and is marked **Unavailable**. Pulls keeps the last known owner and name. It removes that repository only when you uncheck it and save. A failed fetch does not relabel or delete the allowlist. At least one repository must stay selected.

## Notifications

Pulls has two separate notification paths:

- **Development banners.** The menu's "Test notification" and Preferences previews draw Pulls' own banners. They do not use `UNUserNotificationCenter` and they do not ask macOS for permission.
- **System notifications.** Onboarding recommends **Enable Notifications**. That button is the only thing that requests macOS notification permission, along with a later Preferences row if you skipped. **Skip** finishes setup without a prompt. Real pull-request delivery through system notifications is not implemented yet.

If macOS denies the prompt, you can still finish setup. System notifications stay off until you enable them.

## Build, test, and launch

```bash
swift test
scripts/build-app.sh --launch
```

`scripts/build-app.sh` builds a release binary, wraps it in `Pulls.app`, and ad-hoc signs it. The app is a menu-bar item (`LSUIElement`) and does not show a Dock icon. Quit with ⌘Q or **Quit Pulls**.

The bundle still builds when `Config/GitHubOAuth.json` is absent. Sign-in then waits until a client ID is configured.

On launch, Pulls opens setup when there is no saved GitHub credential, or when this account has not finished both the repository step and the notification step. Closing the setup window does not mark setup complete. **Finish setup** in the menu opens it again.

Preferences can change the allowlist or sign out after setup. The inbox keeps showing sample data until pull-request sync exists.

## Phase boundary

This phase stops at authentication, onboarding, the repository allowlist, and persistence. It does not read pull requests, notifications, or review activity from GitHub.
