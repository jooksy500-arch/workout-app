//  WorkoutApp.swift
//  Native iOS shell for the Workout artifact.
//  Replace the contents of the generated WorkoutApp.swift AND delete ContentView.swift.
//
//  What it does:
//   • Loads the artifact live in a WKWebView (same sign-in cookies persist across launches and re-signs).
//   • Injects a tiny bridge (window.WorkoutNative) into every frame, so the artifact page — which lives
//     in an iframe on claude.ai — can ask for Health steps, a hard reload, or SideStore.
//   • Reads today's step count + last 7 days from HealthKit on launch, on foreground resume, and on request.
//   • Reads the embedded provisioning profile's expiry and reports it to the page ("Signed until …").
//   • Optionally hides claude.ai's top bar so the artifact fills the screen.

import SwiftUI
import WebKit
import HealthKit

let ARTIFACT_URL = URL(string: "https://claude.ai/artifact/BGcS2Wf46kfPFNtkP2LmmH")!
let HIDE_CLAUDE_CHROME = true   // set false if the page ever fails to show; the sign-in screen is never hidden

@main
struct WorkoutApp: App {
    var body: some Scene {
        WindowGroup {
            WebScreen().ignoresSafeArea()
        }
    }
}

struct WebScreen: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.websiteDataStore = .default()          // persistent cookies → stays signed in to claude.ai
        let ucc = cfg.userContentController
        ucc.add(context.coordinator, name: "workout")

        // Bridge available in EVERY frame (the artifact runs inside an iframe).
        let bridge = """
        (function(){
          if (window.WorkoutNative) return;
          window.WorkoutNative = {
            send: function(m){ try { window.webkit.messageHandlers.workout.postMessage(m); } catch(e){} },
            hello: function(){ this.send({type:'hello'}); },
            steps: function(){ this.send({type:'steps'}); },
            reload: function(){ this.send({type:'reload'}); },
            sidestore: function(){ this.send({type:'sidestore'}); },
            open: function(u){ this.send({type:'open', url:String(u)}); }
          };
          try { window.dispatchEvent(new Event('workoutnative')); } catch(e){}
        })();
        """
        ucc.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        if HIDE_CLAUDE_CHROME {
            // Main frame only: if the artifact iframe exists, make it fill the window. Sign-in pages have no such iframe.
            let chrome = """
            (function(){
              function fit(){
                var f = document.querySelector('iframe[src*="/artifact"], iframe[src*="artifact"]');
                if (!f) return false;
                f.style.cssText = 'position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;border:0!important;z-index:2147483647!important;background:#fff';
                document.documentElement.style.overflow='hidden'; document.body.style.overflow='hidden';
                return true;
              }
              var tries = 0; var t = setInterval(function(){ if (fit() || ++tries > 60) clearInterval(t); }, 500);
            })();
            """
            ucc.addUserScript(WKUserScript(source: chrome, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.allowsBackForwardNavigationGestures = false
        wv.isOpaque = false
        wv.backgroundColor = .systemBackground
        context.coordinator.webView = wv
        context.coordinator.load()
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var webView: WKWebView?
    private var frame: WKFrameInfo?            // the artifact's frame, learned from its 'hello'
    private let health = HKHealthStore()
    private var lastResume = Date.distantPast

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(onForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func load() {
        guard let wv = webView else { return }
        wv.navigationDelegate = self
        // Always revalidate so a new published version is picked up; never serve a stale copy silently.
        wv.load(URLRequest(url: ARTIFACT_URL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
    }

    // MARK: messages from the page
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        frame = message.frameInfo
        switch type {
        case "hello":
            sendInfo()
            fetchSteps()
        case "steps":
            fetchSteps()
        case "reload":
            webView?.reloadFromOrigin()
        case "sidestore":
            openFirst(["sidestore://refresh", "sidestore://"])
        case "open":
            if let s = body["url"] as? String, let u = URL(string: s) { UIApplication.shared.open(u) }
        default: break
        }
    }

    @objc private func onForeground() {
        // iOS resumes rather than relaunches; re-sync and let the page check for a newer version.
        lastResume = Date()
        eval("window.__wkResume && window.__wkResume();")
        fetchSteps()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOffline(error.localizedDescription)
    }

    private func showOffline(_ msg: String) {
        let html = """
        <meta name=viewport content='width=device-width,initial-scale=1'><body style='font-family:-apple-system;padding:40px 24px;text-align:center;color:#15181c;background:#f2f3ef'>
        <h2 style='margin:0 0 8px'>Can't reach the app</h2><p style='color:#6a7079'>\(msg)</p>
        <p style='color:#6a7079'>Check Wi-Fi or cellular, then tap retry.</p>
        <button onclick='location.href="\(ARTIFACT_URL.absoluteString)"' style='font:600 17px -apple-system;background:#154a2b;color:#fff;border:0;border-radius:14px;padding:14px 22px'>Retry</button></body>
        """
        webView?.loadHTMLString(html, baseURL: nil)
    }

    private func openFirst(_ urls: [String]) {
        for s in urls {
            if let u = URL(string: s), UIApplication.shared.canOpenURL(u) { UIApplication.shared.open(u); return }
        }
        if let u = URL(string: urls.last!) { UIApplication.shared.open(u) }
    }

    // MARK: evaluate JS inside the artifact's frame
    private func eval(_ js: String) {
        guard let wv = webView else { return }
        if let f = frame {
            wv.evaluateJavaScript(js, in: f, in: .page) { _ in }
        } else {
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func sendJSON(_ fn: String, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        eval("window.\(fn) && window.\(fn)(\(s));")
    }

    // MARK: provisioning profile expiry
    private func sendInfo() {
        var info: [String: Any] = ["bundle": Bundle.main.bundleIdentifier ?? "", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? ""]
        if let exp = provisioningExpiry() { info["expires"] = ISO8601DateFormatter().string(from: exp) }
        sendJSON("__wkInfo", info)
    }

    private func provisioningExpiry() -> Date? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    // MARK: HealthKit
    private func fetchSteps() {
        guard HKHealthStore.isHealthDataAvailable(), let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            eval("window.__wkStepsError && window.__wkStepsError('unavailable');"); return
        }
        health.requestAuthorization(toShare: nil, read: [stepType]) { [weak self] ok, _ in
            guard let self = self else { return }
            if !ok { self.eval("window.__wkStepsError && window.__wkStepsError('denied');"); return }
            self.queryWeek(stepType)
        }
    }

    private func queryWeek(_ stepType: HKQuantityType) {
        let cal = Calendar.current
        let now = Date()
        let startToday = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -6, to: startToday)!
        let pred = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let q = HKStatisticsCollectionQuery(quantityType: stepType, quantitySamplePredicate: pred, options: .cumulativeSum, anchorDate: startToday, intervalComponents: DateComponents(day: 1))
        q.initialResultsHandler = { [weak self] _, results, error in
            guard let self = self else { return }
            if error != nil || results == nil { self.eval("window.__wkStepsError && window.__wkStepsError('query');"); return }
            var days: [[String: Any]] = []
            var today = 0.0
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
            results!.enumerateStatistics(from: start, to: now) { stat, _ in
                let v = stat.sumQuantity()?.doubleValue(for: .count()) ?? 0
                let key = df.string(from: stat.startDate)
                days.append(["date": key, "steps": Int(v)])
                if cal.isDateInToday(stat.startDate) { today = v }
            }
            self.sendJSON("__wkSteps", ["today": Int(today), "days": days, "at": ISO8601DateFormatter().string(from: now)])
        }
        health.execute(q)
    }
}
