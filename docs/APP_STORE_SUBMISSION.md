# Gitchat — App Store Connect submission pack

Everything you'll be asked for when filling out the App Store submission form.
Copy-paste ready. Fields marked **🔴 REQUIRED** are mandatory for review.

---

## 1. App record (App Store Connect → My Apps → Gitchat)

| Field | Value |
|-|-|
| **Platform** | iOS |
| **Bundle ID** | `chat.git` |
| **SKU** | `gitchat-ios` |
| **User Access** | Full Access |
| **Primary Language** | English (U.S.) |
| **Default team** | `9S5F8693FB` |

---

## 2. App Information (left sidebar → App Information)

### 🔴 Name (30 chars max)
```
Gitchat
```

### 🔴 Subtitle (30 chars max)
```
Chat with GitHub developers
```

### 🔴 Category
- **Primary**: Social Networking
- **Secondary**: Developer Tools
  *(Note: "Developer Tools" is a Mac-only category. On iOS, pick "Productivity" as secondary instead.)*

### 🔴 Content Rights
- ☐ "Does your app contain, show, or access third-party content?" → **No**
  *(You host user messages but do not display licensed third-party content like music/movies.)*

### 🔴 Age Rating
Go through the questionnaire. Recommended answers:
- Cartoon or Fantasy Violence: **None**
- Realistic Violence: **None**
- Sexual Content or Nudity: **None**
- Profanity or Crude Humor: **Infrequent/Mild** (user-generated chat)
- Horror/Fear Themes: **None**
- Mature/Suggestive Themes: **None**
- Medical/Treatment Information: **None**
- Gambling & Contests: **None**
- Unrestricted Web Access: **Yes** (SFSafariViewController opens any URL shared in chat)
- User-Generated Content + Chat: **Yes, mild** — *"Users can exchange text messages. Moderation is manual."*

Resulting rating will be **12+**.

---

## 3. Pricing and Availability

| Field | Value |
|-|-|
| **Price** | Free |
| **Availability** | All territories |
| **Distribution** | Public |
| **In-App Purchases** | See `IAP_AND_PUSH.md` — enable only after IAP products are configured |

---

## 4. Version information (the "1.0.0" row)

### 🔴 What's New in This Version
First release, leave blank or use:
```
Welcome to Gitchat — the developer chat app that lives on top of GitHub.
```

### 🔴 Promotional Text (170 chars, editable without review)
```
Sign in with GitHub, DM developers you follow, join repo channels, and keep up with contributors — right from your phone. No new friends list to build.
```

### 🔴 Description (4000 chars)
```
Gitchat is the chat app for developers, built on top of GitHub.

Sign in with your GitHub account and instantly see the people you already follow, the repos you contribute to, and the communities around them. No phone book to rebuild. No new handle to remember. Your GitHub username is your Gitchat identity.

WHAT YOU CAN DO

• Direct messages with anyone you follow (or anyone who follows you)
• Group chats with friends you share on GitHub
• Repo channels — dedicated spaces tied to owner/repo, where contributors and fans hang out
• Real-time messaging with typing indicators, reactions, replies, pins, and edits
• Share screenshots and files directly in chat
• Long-press any message to reply, react, copy, edit, pin, or delete
• Social feeds inside each repo channel — X posts, YouTube updates, GitHub activity
• Your friends list is automatically synced from the people you follow on GitHub
• Activity center for mentions, new messages, and repo events
• Light and dark themes, with Geist — the same font used by Vercel

BUILT FOR DEVELOPERS

• Sign in with GitHub — one tap, no passwords
• Sign in with Apple also supported
• Profile shows your top repositories, stars, followers, and contributed projects
• Works alongside the Gitchat extension for VS Code and Cursor — your chats stay in sync whether you're on your phone or in your editor

PRIVACY BY DESIGN

• We never store your GitHub password — authentication goes through GitHub directly
• Messages are private and visible only to the recipients you choose
• You can delete your account at any time

Gitchat is made for the developer community. It's fast, minimal, and built for the way you already work.
```

### 🔴 Keywords (100 chars, comma-separated)
```
github,developer,chat,code,repo,pull request,messaging,dm,friends,git,open source,vscode,cursor
```

### 🔴 Support URL
```
https://gitchat-legal.vercel.app
```
*(Or a dedicated support page — point it at a GitHub Issues link if simpler.)*

### 🔴 Marketing URL (optional)
```
https://gitchat.sh
```

### 🔴 Privacy Policy URL
```
https://gitchat-legal.vercel.app/privacy.html
```

### 🔴 Copyright
```
© 2026 GitchatSH
```

---

## 5. Screenshots (🔴 REQUIRED)

Apple requires the following sizes. You can reuse screenshots across sizes if the aspect ratio is close enough — Apple auto-scales.

### Minimum required
- **6.7" iPhone (1290 × 2796)** — iPhone 15 Pro Max / 16 Pro Max
- **6.5" iPhone (1284 × 2778 or 1242 × 2688)** — iPhone 14 Plus / XS Max
- **5.5" iPhone (1242 × 2208)** — iPhone 8 Plus *(still required!)*

### Optional (skip for phone-only app)
- iPad — skip, `TARGETED_DEVICE_FAMILY = "1"` (iPhone only)

### Suggested screens to capture
1. **Sign-in screen** with the Gitchat logo and the two sign-in buttons
2. **Chats list** with a few sample conversations
3. **Chat detail** showing a bubble conversation with reactions
4. **New chat search** with user results
5. **Profile** with top repos
6. **Settings** with theme options

Use a real device or the iPhone 16 Pro Max simulator. Capture via:
```bash
xcrun simctl io booted screenshot ~/Desktop/screenshot.png
```

### App Preview (video, optional)
Up to 30 seconds. MP4 or MOV. 886 × 1920 or 1080 × 1920. Skip for v1.

---

## 6. App Review Information (🔴 REQUIRED)

### Sign-In Required
☑ **Yes**

### 🔴 Demo Account
You must provide a test account Apple's reviewers can use. Two options:

**Option A — Test GitHub account** (recommended):
1. Create a throwaway GitHub account like `gitchat-reviewer`
2. Username: `gitchat-reviewer`
3. Password: `<throwaway strong password>`
4. Pre-populate with a handful of follows and a couple of conversations so the reviewer sees a non-empty app

**Option B — Apple ID for Sign in with Apple**:
Apple reviewers have an internal test Apple ID; you just need to ensure Sign in with Apple works. *But you still need a GitHub account for the Link GitHub step*, so Option A is simpler.

### 🔴 Contact Information
| Field | Value |
|-|-|
| First name | *(your legal first name)* |
| Last name | *(your legal last name)* |
| Email | `legal@gitchat.sh` or your real email |
| Phone | *(your phone number)* |

### 🔴 Notes for Review
```
Gitchat uses GitHub OAuth for primary sign-in. Please use the demo account credentials above.

Flow:
1. Tap "Sign in with GitHub"
2. Safari sheet opens to github.com — sign in with the provided demo credentials
3. Tap Authorize
4. App automatically loads the main tab view

Sign in with Apple is also available. Apple-signed users are shown a "Link GitHub" screen because the app is built on top of GitHub identity — this is intentional and noted in our Privacy Policy.

Backend API: https://api-dev.gitchat.sh
Realtime: https://ws-dev.gitchat.sh
Web: https://gitchat.sh
Legal: https://gitchat-legal.vercel.app
```

### Attachment
Optional — a screen recording of a successful sign-in flow is very helpful for reviewers.

---

## 7. Privacy — App Privacy Details (🔴 REQUIRED)

Go to **App Store Connect → My Apps → Gitchat → App Privacy**.

### Data types collected

| Category | Data | Linked to user | Used for tracking | Purpose |
|-|-|-|-|-|
| Contact Info | **Email** (optional, from GitHub) | Yes | No | App Functionality |
| Contact Info | **Name** (from GitHub) | Yes | No | App Functionality |
| User Content | **Photos** (attachments) | Yes | No | App Functionality |
| User Content | **Other User Content** (messages, reactions, pins) | Yes | No | App Functionality |
| Identifiers | **User ID** (GitHub login) | Yes | No | App Functionality |
| Usage Data | **Product Interaction** (basic telemetry) | Yes | No | Analytics |
| Diagnostics | **Crash Data** | No | No | App Functionality |

### What you do NOT collect
- ☐ Precise location
- ☐ Payment info (until IAP ships)
- ☐ Health & Fitness
- ☐ Browsing History
- ☐ Search History
- ☐ Sensitive Info
- ☐ Contacts
- ☐ Physical Address
- ☐ Advertising Data

### Tracking
☐ **Does Gitchat track users?** → **No**
*(You don't use IDFA or link data across apps/websites owned by other companies.)*

---

## 8. Encryption / Export Compliance

Already set in Info.plist:
```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

Apple will show a dialog asking "Does your app use non-exempt encryption?" → **No**.

*(The app uses HTTPS and iOS system TLS only — that's exempt under U.S. BIS rules.)*

---

## 9. Advertising Identifier (IDFA)
☐ **Does your app use the Advertising Identifier?** → **No**

---

## 10. Build assignment

After TestFlight processes build 4:
1. App Store Connect → Gitchat → "1.0.0 Prepare for Submission"
2. Scroll to **Build** → click **+ Add Build**
3. Select the latest processed build (currently: build 4)
4. Save

---

## 11. Submit for Review

When everything above is green-checked:
1. Click **Add for Review** (top-right)
2. Answer the final dialog (Export Compliance, Content Rights, Advertising Identifier) — all "No"
3. Click **Submit to App Review**

Expected review time: **24 hours – 3 days** (usually ~24h for a new app).

---

## 12. Expect these rejection risks

Issues Apple typically flags on a first submission like this:

- **Guideline 4.8 (Sign in with Apple)**: you must offer Apple sign-in alongside any other third-party social sign-in. ✅ You have it.
- **Guideline 5.1.1 (Data collection)**: you must ask permission before collecting data that will be tracked across apps. ✅ You don't track.
- **Guideline 2.1 (Accuracy)**: demo account must work when they test. ✅ Prepare one.
- **Guideline 4.2 (Minimum Functionality)**: the app must do something substantive — they sometimes reject "just a chat app that requires another service". You can explain in Review Notes: *"Gitchat is a purpose-built chat client for the GitHub developer community, not a thin wrapper. It provides DM, group chat, repo channels, realtime, and profile discovery."*
- **Guideline 5.2.3 (Third-party trademarks)**: you use the GitHub mark. Safe because the app integrates with GitHub, but be aware.
- **UGC moderation (4.3 / 1.2)**: because the app has user-generated messages, Apple requires:
  1. A method for users to **report objectionable content** — *(not implemented yet; add a Report action to the message context menu before submission)*
  2. A method to **block abusive users** — *(not implemented yet)*
  3. A published **terms of service** — ✅ you have one
  4. **Act on reports within 24 hours** — operational commitment

**→ Before submitting, add Report + Block to the message/profile actions.** This is the most likely rejection. I can add both in ~30 min.

---

## 13. Post-submission checklist

- Monitor **App Store Connect → Activity** for status changes
- Watch your email for reviewer questions
- If rejected: read the rejection, reply via Resolution Center, iterate
- When approved: flip the release toggle (manual or automatic)
