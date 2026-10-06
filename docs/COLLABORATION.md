# Collaboration experiment

Worktree: `MB-Notes-collaboration`. Branch: `experiment/peer-collaboration`, based on the committed `ux-overhaul` branch at `7a82a5d`. The other checkout and its uncommitted UI work are separate.

The target is iOS first, with a small browser companion. The browser adds text, basic pen strokes, and a transient laser pointer. One host owns and saves the note. Guests need a live connection to edit. There is no application backend to operate.

## What this branch implements

The note toolbar's Live Collaboration button opens a session on the current note. The library's More menu offers Join Live Note. Native guests can paste an invitation or scan its QR code. An invitation identifies a document, a fresh session, a PeerJS host, a nearby Bonjour service, and a random bearer token. Browser invitation data lives in the URL fragment. Opening the browser link exposes an Open in MB Notes option for native joining.

`CollaborationWeb` is a React and TypeScript application built with Vite. `Scripts/bundle_collaboration.py` inlines its compiled JavaScript and CSS into one HTML file. That file runs as a static website and inside a native WKWebView. The source UI is React, not a hand-written HTML application. The generated HTML has no runtime CDN dependencies.

`Packages/NoteEngine/Collaboration/session.ts` contains the shared host/replica engine. Swift's `CollaborationFrames` supplies bounded length-prefixed JSON framing for nearby TCP. Transport selection does not change document operations.

Native guests try Bonjour discovery first, using Network.framework with `includePeerToPeer`. Discovery or connection timeout falls back to PeerJS. Browser guests use public PeerJS signaling and WebRTC data channels. Connections can use direct ICE candidates or a TURN relay. Nearby sharing does not need public signaling, but physical devices must prove discovery and radio behavior. See [Apple's peer-to-peer option](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer).

The host orders additions and removals, validates authorship and geometry, waits for persistence, then broadcasts a revision and acknowledgment. Stable operation IDs suppress retries within a session. Reconnecting guests receive a fresh snapshot and retry submitted, unacknowledged changes. New changes are disabled while disconnected. Sessions admit one owner plus nine guests. Document snapshots are bounded to 2 MiB and nearby frames to 4 MiB; a size-limit rejection asks the owner to start a new session. This clears session overlays into the native saved baseline.

Browser text becomes native page text. Browser pen samples become PencilKit strokes. The native canvas is suspended while the shared editor is open and rebuilt after the session closes, so its older drawing cannot overwrite accepted remote ink. The native undo stack resets at that boundary. The collaboration editor can undo the current participant's additions during the session.

The native renderer sends page backgrounds on demand at 1200 pixels wide. Backgrounds include existing imported PDF pages, converted slides, paper, text, and ink. Shared additions remain separate overlays. Imports stay in the native app; the browser does not convert PPTX or edit existing native content. A native session reopening uses the saved content as its new background. Presentation-following and infinite whiteboard coordinates are not implemented in this experiment.

Presence and laser positions expire after 1.5 seconds. They never become document operations, stored ink, or undo entries. The prototype ends a native session when the app backgrounds. It does not transfer ownership or promise background hosting.

## Network resilience and the relay failure

Public PeerJS signaling worked in the two-browser experiment. Text, pen, laser expiry, guest reconnection, and host closure passed through real data channels. A test forced `iceTransportPolicy: "relay"` on both clients and failed to connect.

The bundled default tries Open Relay's documented static-auth host on TCP ports 80 and 443, including TLS on 443. The ICE probe obtained no relay candidates. Documentation alone is not evidence that the shared public endpoint works. See [Open Relay's current setup and static-auth instructions](https://www.metered.ca/tools/openrelay/).

The Connection options dialog accepts a provider's ICE servers JSON and stores it on that device. Set the configuration on both participants before starting or joining a new session. Use short-lived provider credentials for a real deployment. The relay audit command below must pass before calling this network-resilient. This test uses the configured provider, rather than silently replacing a relay-only test with a direct connection.

TURN addresses difficult NATs and blocked direct paths. It cannot repair a blocked signaling domain, a network that permits only an authenticated HTTP proxy, or every deep inspection policy. PeerJS's public signaling is another dependency and currently has no alternative signaling transport in this branch. See the [PeerJS networking FAQ](https://peerjs.com/client/faq) and [WebRTC TURN documentation](https://webrtc.org/getting-started/turn-server).

For the A&M check, use two physical iOS devices on that network and an actual off-network browser. Test nearby discovery, direct candidates, relay-only TCP/TLS, blocked signaling, Wi-Fi changes, an unavailable relay, local network permission denial, and owner backgrounding separately. Record the selected route and failure, not just whether the UI says Connected. Network.framework's peer-to-peer setting is a path to investigate, not proof that an organization allows it.

There are free managed options to investigate before treating this as a dead end. [Metered’s current Realtime/Open Relay documentation](https://www.metered.ca/tools/openrelay/webrtc-library/) advertises 20 GB/month of TURN and free signaling up to 100 connections and 100,000 messages/month, with an account and a browser publishable key. Its alternate signaling adapter could also remove dependence on the single PeerJS domain. It has not been integrated or tested here.

[Cloudflare Realtime TURN](https://www.cloudflare.com/products/turn-sfu/) advertises 1,000 GB/month free, then $0.05/GB. It needs an account and authenticated [short-lived credential generation](https://developers.cloudflare.com/realtime/turn/generate-credentials/). An owner device could hold the API secret privately and issue temporary guest credentials, or a small managed function could do that. Never bundle the account API secret in the public React artifact. Neither option requires renting or maintaining a TURN server, but free quotas and billing controls still need checking. These are candidates for later testing, not evidence that campus connectivity already works.

The nearby prototype is token-authenticated TCP without application TLS. WebRTC data channels encrypt traffic. This experiment has no host promotion, durable guest replica, or peer authorization beyond the invitation token. Share disposable test notes while evaluating it.

## Why this does not begin with a React Native migration

Keeping the native application preserves PencilKit, the import pipeline, existing note files, and the iOS UI. A shared React collaboration editor already gives iOS and browser the same interaction and session code. A full React Native rewrite would still need native modules/components for PencilKit, file imports, and nearby links. See [React Native's native platform documentation](https://reactnative.dev/docs/native-platform).

If the embedded editor proves unsuitable on iOS, replace that editor or WebRTC transport behind the same protocol. The experiment does not require replacing the rest of the application first.

## Offline merging later

This engine is a connected host/replica protocol, not an offline CRDT. Pending submitted changes survive a transport interruption in memory; tab/app termination loses that guest queue. Accepted native changes persist in the host's note. Save acknowledgment follows the existing note writer, which writes manifest and ink files separately. Memory rollback on a write failure is best effort; there is no crash-safe operation journal across files.

For durable offline replicas, define stable object/page IDs, CRDT text, deletion rules, immutable attachment hashes, and per-author undo. Automerge has interoperable Swift and JavaScript implementations, so offline merging also does not require React Native. See [Automerge Swift](https://github.com/automerge/automerge-swift) and [Automerge repositories](https://automerge.org/docs/reference/repositories/). A migration needs schema and restart/reconciliation tests before claiming reliable offline merges.

The published React browser demo is [available here](https://planista.shloklab.us/yO58sbtpOzrT4Yzz). It is an unlisted static prototype, published through the file-upload workflow.

## Run and verify

Use Node 22 or newer and Python 3:

```sh
cd CollaborationWeb
npm ci
npm test
npm run build
npm run dev
```

`dist/index.html` is the standalone website. The build also copies it to `MBNotes/Resources/Collaboration/index.html` for the app. `MBNotes/Resources/Collaboration.json` supplies the public website URL used by native invitations. Generated HTML is ignored by Git and rebuilt by both Gala recipes.

```sh
cd Packages/NoteEngine
swift test
```

The browser interaction gate uses real public signaling and two isolated browser contexts:

```sh
cd CollaborationWeb
npx playwright install chromium
npm run test:e2e
```

The explicit relay audit is separate because its current default public provider failed:

```sh
MB_ICE_SERVERS='[{"urls":"turns:YOUR_PROVIDER:443?transport=tcp","username":"USER","credential":"PASSWORD"}]' npm run test:relay
```

The native gate builds an optimized Release app, enables Gala output capture, and runs unit and native UI tests on a temporary iPad simulator while a second iPhone simulator hosts an imported note. Browser tests finish before Xcode starts. UI tests click the host/join entries, type, draw, use the laser, show the QR invitation, close the session, and restart to check saved text. A guest joins the second iOS app by invitation URL, writes text and ink, and checks the owner’s persisted state. After XCTest finishes, the published browser client joins a fresh native owner and checks saved text, ink, and transient laser behavior. Native tests also verify saved PencilKit content and nine loopback TCP guest streams. Loopback tests are not a physical nearby-network test.

```sh
gala test --host local --json
```

Review the screenshots and captured app logs. A simulator cannot prove camera scanning, device-to-device radio discovery, Pencil hardware behavior, or A&M policy. A ten-person admission test is not a ten-device performance measurement.
