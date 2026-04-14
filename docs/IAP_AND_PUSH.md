# IAP + Push Notifications — step-by-step guide

Two big integrations:
1. **In-App Purchases** (StoreKit 2) — Gitchat Pro subscription + one-time power-ups
2. **Push Notifications** via **OneSignal** — message/mention alerts even when the app is backgrounded

---

## Part A — In-App Purchases

### A.1 Suggested product lineup

Keep it small. Three products, tiered clearly:

| Product | Type | Price | Product ID |
|-|-|-|-|
| **Gitchat Pro** (monthly) | Auto-renewable subscription | $3.99/mo | `chat.git.pro.monthly` |
| **Gitchat Pro** (yearly) | Auto-renewable subscription | $29.99/yr | `chat.git.pro.yearly` |
| **Supporter** (one-time) | Non-consumable | $9.99 | `chat.git.supporter` |

**Why these three?**
- Monthly is the on-ramp
- Yearly saves the user ~37% and locks them in
- Supporter is for people who want to pay once forever — common in dev-focused apps

### A.2 What Pro unlocks (benefits)

Pick a subset — you don't need all of these on day 1:

**High value, easy to build:**
1. **Unlimited message history** — free tier limited to last 30 days of DMs
2. **Larger file uploads** — free: 10 MB, Pro: 100 MB
3. **Pro badge on your profile** — little orange star next to your @handle
4. **Custom accent color** — pick any color for your chat bubbles
5. **All themes unlocked** — free gets System/Light/Dark; Pro gets Dim, Midnight, Solarized, Dracula
6. **HD image upload** — free tier downsizes to 1080, Pro keeps original

**Medium effort, high perceived value:**
7. **Unlimited group size** — free capped at 8, Pro unlimited
8. **Search all message history** — free: search last 1000, Pro: search everything
9. **Priority push notifications** — (needs push first)
10. **Early access features** — ship beta features to Pro users first

**Developer-specific (unique to Gitchat):**
11. **Rich repo previews in messages** — paste a GitHub URL, get a live card with stars/description/PRs
12. **AI reply suggestions** — tap to get 3 contextual replies from Claude/GPT
13. **Code snippet syntax highlighting** — multi-language syntax in chat bubbles
14. **Unlimited channel subscriptions** — free: 5 repo channels, Pro: unlimited
15. **GitHub activity digest** — daily DM summary of activity on repos you follow

**Vanity + community:**
16. **Pro-only emoji reactions** — animated emojis and custom repo-flavored reactions
17. **Supporter wall** — your name listed on gitchat-legal/supporters.html forever
18. **Gitchat Pro sticker pack** — 1 physical sticker mailed to supporters (cost of goods $2)

**My recommendation for v1.0:** ship items **1, 3, 4, 5, 6, 14**. Those are all 100% iOS-side, no backend changes, and immediately visible to the user on day 1. Add 11–15 in 1.1 once you see whether IAP converts.

### A.3 Create the products in App Store Connect

1. **App Store Connect** → My Apps → Gitchat → **In-App Purchases** (sidebar)
2. Click **`+`** → choose type:
   - Auto-renewable subscription → create **Subscription Group** first (name it "Gitchat Pro")
   - Non-consumable → direct
3. For each product:
   - Reference name: internal label, e.g. "Pro Monthly"
   - Product ID: use the IDs in the table above (matches what you'll use in Swift)
   - Price: pick tier
   - Localizations (English US minimum):
     - Display name: "Gitchat Pro"
     - Description: "Unlock unlimited history, larger uploads, custom themes, and a Pro badge."
   - Review screenshot: a single screenshot showing the Pro upsell screen in your app (640×920+)
   - Review notes: "Gitchat Pro is a recurring subscription. Tap Settings → Upgrade to Pro to initiate purchase."
4. Status → **Ready to Submit** (until then it won't be loadable from StoreKit)
5. Add both subscriptions to the **same subscription group** so users can switch between monthly/yearly without paying twice.

### A.4 Agreements, Tax, and Banking

⚠️ **Before StoreKit returns any products, you MUST complete the Paid Apps Agreement:**

1. App Store Connect → **Agreements, Tax, and Banking**
2. Paid Apps Agreement → **Request** → sign
3. **Contact Info** → fill in
4. **Bank Account** → add your bank (US: routing + account; elsewhere: SWIFT/IBAN)
5. **Tax forms**:
   - US sellers: W-9
   - Non-US: W-8BEN (individual) or W-8BEN-E (company)
6. Wait for **"Active"** status (can take a few hours to a day)

Until this is active, `StoreKit` returns an empty product list even if products exist.

### A.5 Enable the In-App Purchase capability

This is already possible with automatic signing — Xcode auto-adds it when it sees your StoreKit code. But to be explicit, add to `project.yml`:

```yaml
entitlements:
  path: GitchatIOS/GitchatIOS.entitlements
  properties:
    com.apple.developer.applesignin:
      - Default
    # (StoreKit doesn't actually need an explicit entitlement — the capability
    # is enabled by the presence of the App ID on the Developer portal)
```

Also in App Store Connect → **Developer → Identifiers → chat.git** → check **In-App Purchase** → Save.

### A.6 iOS code: StoreKit 2 integration

This is the skeleton. I can build this out when you give the go-ahead.

#### `Core/StoreKit/StoreManager.swift`
```swift
import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlements: Set<String> = []

    private let productIDs: Set<String> = [
        "chat.git.pro.monthly",
        "chat.git.pro.yearly",
        "chat.git.supporter"
    ]

    var isPro: Bool {
        entitlements.contains("chat.git.pro.monthly") ||
        entitlements.contains("chat.git.pro.yearly") ||
        entitlements.contains("chat.git.supporter")
    }

    private var updatesTask: Task<Void, Never>?

    func start() {
        updatesTask = Task { await listenForTransactions() }
        Task { await loadProducts(); await refreshEntitlements() }
    }

    func loadProducts() async {
        do { products = try await Product.products(for: productIDs) }
        catch { print("product load failed: \(error)") }
    }

    func purchase(_ product: Product) async throws {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            if case .verified(let tx) = verification {
                entitlements.insert(tx.productID)
                await tx.finish()
            }
        case .userCancelled, .pending: break
        @unknown default: break
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    private func refreshEntitlements() async {
        entitlements.removeAll()
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result {
                entitlements.insert(tx.productID)
            }
        }
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let tx) = result {
                entitlements.insert(tx.productID)
                await tx.finish()
            }
        }
    }
}
```

#### `Features/Pro/UpgradeView.swift` — the paywall
```swift
struct UpgradeView: View {
    @EnvironmentObject var store: StoreManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // header / benefits / CTA
            ForEach(store.products) { p in
                Button { Task { try? await store.purchase(p) } } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.displayName).bold()
                            Text(p.description).font(.caption)
                        }
                        Spacer()
                        Text(p.displayPrice).bold()
                    }
                    .padding().background(.orange.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Button("Restore Purchases") { Task { try? await store.restore() } }
        }
    }
}
```

Wire `StoreManager.shared.start()` in `GitchatApp.init()`, inject via `.environmentObject`. Add an "Upgrade to Pro" row in `SettingsView`.

### A.7 Server-side receipt validation (optional but recommended)

StoreKit 2 gives you JWS-signed receipts that you can verify server-side to gate Pro-only endpoints. If you add this, the backend needs:

- `POST /pro/verify-receipt` — takes the JWS, returns `{ active, expires_at, product_id }`
- Apple's public certs to verify the JWS signature
- A column `user_profiles.pro_until: timestamptz`

I can build this as a separate PR when you're ready.

### A.8 Testing IAP

1. **Xcode → Product → Scheme → Edit Scheme → Options → StoreKit Configuration** → create a `.storekit` file with your products for offline local testing
2. Or: **Sandbox** — create a sandbox tester at App Store Connect → Users & Access → Sandbox Testers → sign into the device with that Apple ID → purchases are free

---

## Part B — Push Notifications with OneSignal

OneSignal is the fastest way to ship push without building a notification service yourself. Free tier handles unlimited subscribers up to 10k/month.

### B.1 Create the OneSignal app

1. Go to https://onesignal.com → Sign up / log in with GitHub
2. **New App/Website** → name it "Gitchat"
3. Select **Apple iOS (APNs)** as the platform
4. **Choose your APNs credentials method**: **Token-based (.p8)** ← pick this, it's easier than certificates

### B.2 Create an APNs Auth Key in Apple Developer

1. https://developer.apple.com/account/resources/authkeys/list
2. **`+`** → **Apple Push Notifications service (APNs)** → Continue
3. Name: `Gitchat APNs`
4. Register → **Download** the `.p8` file (you can only download it once — save it to a password manager)
5. Copy the **Key ID** shown on screen

### B.3 Enable Push Notifications for your App ID

1. https://developer.apple.com/account/resources/identifiers/list
2. Click **chat.git** → scroll to **Push Notifications** → check → **Save**
3. Your Xcode `-allowProvisioningUpdates` will auto-regenerate the provisioning profile on next archive

### B.4 Paste credentials into OneSignal

In the OneSignal setup wizard:
| Field | Value |
|-|-|
| Bundle ID | `chat.git` |
| Team ID | `9S5F8693FB` |
| Key ID | *(from step B.2)* |
| Auth Key File | *(upload the `.p8` from B.2)* |

Click **Save & Continue**.

On the next screen you'll see your **OneSignal App ID** — a UUID like `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`. **Copy this** — you need it on both client and server.

### B.5 Add OneSignal SDK to the iOS project

**Via SPM** — add to `project.yml`:

```yaml
packages:
  SocketIO:
    url: https://github.com/socketio/socket.io-client-swift
    from: "16.1.0"
  OneSignal:
    url: https://github.com/OneSignal/OneSignal-iOS-SDK
    from: "5.2.0"

targets:
  GitchatIOS:
    # ...
    dependencies:
      - package: SocketIO
        product: SocketIO
      - package: OneSignal
        product: OneSignalFramework
```

Then `xcodegen generate` to pick it up.

### B.6 Add the Notification Service Extension (for rich pushes)

OneSignal requires a service extension to decrypt and enrich pushes (attachments, images). In `project.yml`:

```yaml
targets:
  OneSignalNotificationServiceExtension:
    type: app-extension
    platform: iOS
    deploymentTarget: "16.0"
    sources:
      - path: OneSignalNotificationServiceExtension
    dependencies:
      - package: OneSignal
        product: OneSignalExtension
    info:
      path: OneSignalNotificationServiceExtension/Info.plist
      properties:
        CFBundleDisplayName: OneSignalNotificationServiceExtension
        NSExtension:
          NSExtensionPointIdentifier: com.apple.usernotifications.service
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).NotificationService
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: chat.git.OneSignalNotificationServiceExtension
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: 9S5F8693FB
```

Create `OneSignalNotificationServiceExtension/NotificationService.swift`:
```swift
import UserNotifications
import OneSignalExtension

class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var receivedRequest: UNNotificationRequest!
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.receivedRequest = request
        self.contentHandler = contentHandler
        self.bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        if let bestAttemptContent {
            OneSignalExtension.didReceiveNotificationExtensionRequest(
                self.receivedRequest,
                with: bestAttemptContent,
                withContentHandler: self.contentHandler
            )
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            OneSignalExtension.serviceExtensionTimeWillExpireRequest(
                self.receivedRequest,
                with: bestAttemptContent
            )
            contentHandler(bestAttemptContent)
        }
    }
}
```

### B.7 App Groups (required for service extension → main app data sharing)

1. In App Store Connect → Developer → Identifiers:
   - Create App Group `group.chat.git.onesignal`
   - Add it to both `chat.git` and `chat.git.OneSignalNotificationServiceExtension` App IDs

2. In `project.yml` for both targets, add to entitlements:
```yaml
com.apple.security.application-groups:
  - group.chat.git.onesignal
```

### B.8 Initialize OneSignal in the app

Edit `App/GitchatApp.swift`:

```swift
import OneSignalFramework

@main
struct GitchatApp: App {
    init() {
        OneSignal.initialize("YOUR_ONESIGNAL_APP_ID", withLaunchOptions: nil)
        OneSignal.Notifications.requestPermission({ accepted in
            print("push accepted: \(accepted)")
        }, fallbackToSettings: true)
    }
    // ...
}
```

When the user signs in, tell OneSignal who they are so you can target pushes:

```swift
// Call after successful auth in AuthStore.save()
OneSignal.login(login)   // use the GitHub login as external user ID
```

On sign out:
```swift
OneSignal.logout()
```

### B.9 Backend: trigger pushes from NestJS

When a new message arrives, the backend should call OneSignal's REST API to push to the recipient's `external_id` (their GitHub login).

```typescript
// backend: src/modules/notifications/onesignal.service.ts
import { Injectable } from '@nestjs/common';

@Injectable()
export class OneSignalService {
  private readonly appId = process.env.ONESIGNAL_APP_ID!;
  private readonly restKey = process.env.ONESIGNAL_REST_API_KEY!;

  async notifyUser(login: string, title: string, body: string, data?: Record<string, any>) {
    await fetch('https://api.onesignal.com/notifications', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Key ${this.restKey}`,
      },
      body: JSON.stringify({
        app_id: this.appId,
        target_channel: 'push',
        include_aliases: { external_id: [login] },
        headings: { en: title },
        contents: { en: body },
        data,
      }),
    });
  }
}
```

Wire it into the `MessagesService.send` path so every new message fires a push to recipients that aren't the sender.

### B.10 Env vars for the backend

Add to your deploy env:
```
ONESIGNAL_APP_ID=<your app id>
ONESIGNAL_REST_API_KEY=<from OneSignal Settings → Keys & IDs → REST API Key>
```

### B.11 Testing push

1. Build + install a Release build on a real device (sim doesn't receive real push — simulator can receive local only)
2. Sign in — you'll see the permission prompt, allow it
3. OneSignal Dashboard → **Audience → Subscriptions** → you should see your device within a few seconds
4. **Messages → New Push** → pick "Gitchat" → target "All Subscriptions" → write a test message → Send
5. Phone receives it within seconds

---

## Cross-cutting — what to do first

**Order of operations I recommend:**

1. **Submit for App Store Review WITHOUT IAP and WITHOUT push** (just the core chat app) — this gets you the approval and a published listing. Reviewers are faster on simpler apps.
2. **Ship v1.1 with push notifications** (OneSignal) — operational benefit, no App Store risk
3. **Ship v1.2 with IAP** — revenue features, but also means additional review scrutiny (the Paid Apps Agreement has to be active, the paywall has to be reachable, products must be submitted with the app, etc.)

Trying to ship all three at once triples the rejection surface. One thing at a time.

---

## Quick reference

### IDs you'll need
| Label | Value |
|-|-|
| Bundle ID | `chat.git` |
| Team ID | `9S5F8693FB` |
| OneSignal App ID | *(after setup)* |
| Pro Monthly Product ID | `chat.git.pro.monthly` |
| Pro Yearly Product ID | `chat.git.pro.yearly` |
| Supporter Product ID | `chat.git.supporter` |
| App Group (OneSignal) | `group.chat.git.onesignal` |
| Service Extension Bundle | `chat.git.OneSignalNotificationServiceExtension` |

### Env vars (backend)
```
# IAP
APPLE_SHARED_SECRET=<from ASC → Users & Access → App-Specific Shared Secret, only needed for receipt validation>

# OneSignal
ONESIGNAL_APP_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
ONESIGNAL_REST_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Tell me which one you want me to implement first and I'll do the iOS code in the next round.
