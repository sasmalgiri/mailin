//
//  AIScaffoldContractTests.swift
//  ArchiveCoreTests
//
//  Plan v4 SCAF-01…03 / B02 / B03 / B04: the AI scaffolding contracts, with
//  fakes only. No test here opens a connection or needs a real key: the
//  "transport" is `MockAITransport`, the Keychain is `InMemoryAISecretKeychain`.
//

import XCTest
import Foundation
import Security
@testable import ArchiveCore

final class AIScaffoldContractTests: XCTestCase {

    // MARK: Fixtures

    private let checked = Date(timeIntervalSince1970: 1_794_182_400) // 2026-11-09
    private var price: AIPriceTable {
        AIPriceTable(modelID: "model-a", inputPerMillionTokens: 4, outputPerMillionTokens: 20, checkedOn: checked)
    }

    private func profile(_ provider: AIProviderKind = .anthropic, host: String = "api.provider-a.example",
                         model: String = "model-a") -> AIProviderProfile {
        AIProviderProfile(provider: provider, endpoint: AIEndpoint(host: host, ownership: .providerOperated), modelID: model)
    }

    private func sources(_ origins: [AISourceOrigin] = [.fileImport, .fileImport]) -> AISourceSelection {
        AISourceSelection(items: origins.map { AISourceItem(messageID: UUID(), origin: $0) },
                          dataTypes: [.headers, .messageBody])
    }

    private func request(_ p: AIProviderProfile, payload: String = "What did Asha say about the invoice?",
                         sources s: AISourceSelection? = nil, trigger: AITrigger = .userAction,
                         price pt: AIPriceTable?? = .none) -> AIRequest {
        let table: AIPriceTable? = pt ?? price
        return AIRequest(profile: p, purpose: .question, trigger: trigger, sources: s ?? sources(),
                         payload: Data(payload.utf8), promptVersion: "q-1", maxOutputTokens: 512, price: table)
    }

    private struct Rig {
        let policy: AIPolicy
        let keychain: InMemoryAISecretKeychain
        let keys: AIKeyProfileStore
        let grants: AIGrantRegistry
        let budget: AIRunBudget
        let ledger: InMemoryAIUsageLedger
        let transport: MockAITransport
        let counters: AIScaffoldCounters
    }

    /// A rig whose policy believes a runtime shipped, so the rules behind that
    /// switch can be exercised with the mock transport.
    private func rig(_ script: MockAITransport.Script = .success(text: "ok", usage: AIUsage(inputTokens: 10, outputTokens: 5)),
                     budget: AIRunBudget = AIRunBudget(perRunLimit: 1, periodLimit: 10)) -> Rig {
        let policy = AIPolicy(runtimeShipped: true)
        policy.setCloudAIEnabled(true)
        let keychain = InMemoryAISecretKeychain()
        return Rig(policy: policy, keychain: keychain, keys: AIKeyProfileStore(keychain: keychain, useDataProtectionKeychain: false),
                   grants: AIGrantRegistry(), budget: budget, ledger: InMemoryAIUsageLedger(),
                   transport: MockAITransport(script), counters: AIScaffoldCounters())
    }

    private func coordinator(_ r: Rig, consent: any AIConsentBroker, entitled: Bool = true,
                             eligibility: any AISourceEligibility = AISourcePolicy(),
                             transport: (any AITransport)? = nil) -> AIRequestCoordinator {
        AIRequestCoordinator(policy: r.policy, entitlement: FixedAIEntitlement(entitled), eligibility: eligibility,
                             keys: r.keys, consent: consent, grants: r.grants, budget: r.budget, ledger: r.ledger,
                             transport: transport ?? r.transport, counters: r.counters)
    }

    // MARK: SCAF-01 — production transport, results, actual engine

    func testSCAF01_productionDefaultsRefuseEveryRequest_noPromptNoKeyReadNoTransport() async throws {
        XCTAssertFalse(AIProductionTransport.liveInferenceShipped)
        XCTAssertFalse(AIProductionTransport.current.isAvailable)
        XCTAssertFalse(AIPolicy.shared.isRuntimeShipped)
        XCTAssertFalse(AIPolicy.shared.isCloudAIEnabled, "AI is off on a fresh install")

        let keychain = InMemoryAISecretKeychain()
        let keys = AIKeyProfileStore(keychain: keychain, useDataProtectionKeychain: false)
        let p = profile()
        try keys.add(Data("customer-key-1".utf8), for: p.credentialReference)
        let consent = ScriptedConsentBroker(.grantExactly)
        let counters = AIScaffoldCounters()
        // Everything else as permissive as possible: Pro, a key, a yes, money.
        let production = AIRequestCoordinator(policy: AIPolicy(), entitlement: FixedAIEntitlement(true), keys: keys,
                                              consent: consent, budget: AIRunBudget(perRunLimit: 100, periodLimit: 100),
                                              counters: counters)
        let enabledPolicy = AIPolicy()
        enabledPolicy.setCloudAIEnabled(true)
        XCTAssertNil(enabledPolicy.register {}, "no AI work can even be registered without a runtime")
        let stillProduction = AIRequestCoordinator(policy: enabledPolicy, entitlement: FixedAIEntitlement(true), keys: keys,
                                                   consent: consent, budget: AIRunBudget(perRunLimit: 100, periodLimit: 100),
                                                   counters: counters)
        for c in [production, stillProduction] {
            let r = await c.submit(request(p))
            XCTAssertEqual(r.status, .error(.runtimeNotShipped))
            XCTAssertEqual(r.transportCalls, 0)
            XCTAssertEqual(r.actualEngine, .none)
            XCTAssertEqual(c.snapshot.consentPrompts, 0)
            XCTAssertEqual(c.snapshot.keyReads, 0)
            XCTAssertEqual(c.snapshot.transportInvocations, 0)
        }
        // A runtime that "shipped" but still has the production transport: refused before consent.
        let r = rig()
        let withProductionTransport = coordinator(r, consent: consent, transport: AIProductionTransport.current)
        let refused = await withProductionTransport.submit(request(p))
        XCTAssertEqual(refused.status, .error(.transportUnavailable))
        XCTAssertEqual(withProductionTransport.snapshot.consentPrompts, 0)
        XCTAssertTrue(consent.askedRequests.isEmpty, "no consent sheet for a request that cannot run")
        do {
            _ = try await UnavailableAITransport().perform(request(p), secret: AISecret(Data("x".utf8)))
            XCTFail("the production transport must throw")
        } catch let f as AIFailure { XCTAssertEqual(f, .transportUnavailable) }
        XCTAssertEqual(counters.snapshot().transportInvocations, 0)
        XCTAssertEqual(counters.snapshot().submitted, 2)
    }

    func testSCAF01_mockOutcomes_successPartialErrorCancelled_reportActualEngine() async throws {
        let p = profile()
        let engine = AIEngineIdentity.cloud(provider: .anthropic, modelID: "model-a", endpointHost: "api.provider-a.example")
        let cases: [(MockAITransport.Script, AIResultStatus, AIEngineIdentity, AIBillingCertainty)] = [
            (.success(text: "done", usage: AIUsage(inputTokens: 3, outputTokens: 2)), .success, engine, .reported),
            (.partial(text: "half", reason: "stream ended without a stop event", usage: nil),
             .partial(reason: "stream ended without a stop event"), engine, .uncertain),
            (.failure(.provider(message: "overloaded")), .error(.provider(message: "overloaded")), .none, .uncertain),
            (.cancelled, .cancelled, .none, .uncertain),
            (.answeredBy(modelID: "model-cheaper", text: "hi"), .success,
             .cloud(provider: .anthropic, modelID: "model-cheaper", endpointHost: "api.provider-a.example"), .uncertain),
        ]
        for (script, status, actual, billing) in cases {
            let r = rig(script)
            try r.keys.add(Data("k".utf8), for: p.credentialReference)
            let c = coordinator(r, consent: ScriptedConsentBroker(.grantExactly))
            let result = await c.submit(request(p))
            XCTAssertEqual(result.status, status, "\(script)")
            XCTAssertEqual(result.actualEngine, actual, "the engine that answered, not the one requested")
            XCTAssertEqual(result.transportCalls, 1)
            XCTAssertEqual(r.ledger.entries().count, 1, "a call that reached the transport is in the ledger")
            XCTAssertEqual(r.ledger.entries().first?.billing, billing)
        }
        // A partial result is never success.
        XCTAssertNotEqual(AIResultStatus.partial(reason: "x"), .success)
    }

    func testSCAF01_aiPolicyRefusesMailHostsLocalHostsAndIsIndependent() {
        for host in ["imap.gmail.com", "smtp.gmail.com", "gmail.googleapis.com", "graph.microsoft.com",
                     "outlook.office365.com", "login.microsoftonline.com", "accounts.google.com", "imap.example.org",
                     "smtp.office365.com", "mail.example.com"] {
            XCTAssertTrue(AIPolicy.isMailHost(host), host)
            XCTAssertEqual(AIPolicy.destinationRefusal(request(profile(host: host))), .mailHostRefused, host)
        }
        for host in ["localhost", "127.0.0.1", "10.0.0.2", "printer.local", "https://api.x.example", "api.x.example:443",
                     "user@api.x.example", "api.x.example/v1", "", "nodot"] {
            XCTAssertEqual(AIPolicy.destinationRefusal(request(profile(host: host))), .invalidEndpoint, host)
        }
        XCTAssertNil(AIPolicy.destinationRefusal(request(profile(host: "api.provider-a.example"))))
        // Off cancels registered AI work and refuses new work.
        let policy = AIPolicy(runtimeShipped: true)
        XCTAssertNil(policy.register {}, "off: nothing registers")
        policy.setCloudAIEnabled(true)
        let cancelled = AIOnce<Bool>()
        XCTAssertNotNil(policy.register { cancelled.resolve(true) })
        policy.setCloudAIEnabled(false)
        XCTAssertEqual(cancelled.resolved, true)
        XCTAssertEqual(policy.cancelledTasks, 1)
        XCTAssertEqual(policy.refusal(for: request(profile())), .aiDisabled)
        // AI keys never share a Keychain service with mail credentials.
        XCTAssertNotEqual(AIKeyProfileStore.service, "com.ecosanskriti.mailin.connected-account")
        XCTAssertNotEqual(AIKeyProfileStore.service, "com.ecosanskriti.mailin")
    }

    // MARK: SCAF-03 — consent, eligibility, cancellation, budgets, ledger

    func testSCAF03_deniedPendingCancelledRevokedConsent_zeroTransportCalls() async throws {
        let p = profile()
        for answer in [ScriptedConsentBroker.Answer.deny, .pending, .cancel] {
            let r = rig()
            try r.keys.add(Data("k".utf8), for: p.credentialReference)
            let c = coordinator(r, consent: ScriptedConsentBroker(answer))
            let result = await c.submit(request(p))
            XCTAssertEqual(result.transportCalls, 0, "\(answer)")
            XCTAssertEqual(c.snapshot.transportInvocations, 0)
            XCTAssertEqual(c.snapshot.keyReads, 0, "the key is not even read without a yes")
            XCTAssertTrue(r.transport.calls.isEmpty)
            XCTAssertTrue(r.ledger.entries().isEmpty)
        }
        // Revoked while the sheet was up.
        let r = rig()
        try r.keys.add(Data("k".utf8), for: p.credentialReference)
        let req = request(p)
        let grant = AIConsentGrant(approving: req)
        let grants = r.grants
        let c = coordinator(r, consent: ScriptedConsentBroker(.grant(grant), beforeAnswer: { _ in grants.revoke(grant.id) }))
        let revoked = await c.submit(req)
        XCTAssertEqual(revoked.status, .error(.consentRevoked))
        XCTAssertTrue(r.transport.calls.isEmpty)
        // AI switched off while the sheet was up.
        let r2 = rig()
        try r2.keys.add(Data("k".utf8), for: p.credentialReference)
        let policy = r2.policy
        let off = coordinator(r2, consent: ScriptedConsentBroker(.grantExactly, beforeAnswer: { _ in policy.setCloudAIEnabled(false) }))
        let offResult = await off.submit(request(p))
        XCTAssertEqual(offResult.status, .error(.aiDisabled))
        XCTAssertTrue(r2.transport.calls.isEmpty)
        // Entitlement lost while the sheet was up.
        final class Flip: AIEntitlementGate, @unchecked Sendable { var allowsAIWork = true }
        let flip = Flip()
        let r3 = rig()
        try r3.keys.add(Data("k".utf8), for: p.credentialReference)
        let lapsing = AIRequestCoordinator(policy: r3.policy, entitlement: flip, keys: r3.keys,
                                           consent: ScriptedConsentBroker(.grantExactly, beforeAnswer: { _ in flip.allowsAIWork = false }),
                                           budget: r3.budget, transport: r3.transport, counters: r3.counters)
        let lapsed = await lapsing.submit(request(p))
        XCTAssertEqual(lapsed.status, .error(.notEntitled))
        XCTAssertTrue(r3.transport.calls.isEmpty)
    }

    /// B03 / TA04: switching provider while consent is open cannot cross-route
    /// the key, the payload or the budget.
    func testSCAF03_B03_providerSwitchDuringConsent_cannotRedirectKeyOrPayload() async throws {
        let a = profile(.anthropic, host: "api.provider-a.example", model: "model-a")
        let b = profile(.openAI, host: "api.provider-b.example", model: "model-b")
        let r = rig()
        try r.keys.add(Data("key-for-A".utf8), for: a.credentialReference)
        try r.keys.add(Data("key-for-B".utf8), for: b.credentialReference)

        final class Selection: @unchecked Sendable { var profile: AIProviderProfile; init(_ p: AIProviderProfile) { profile = p } }
        let selected = Selection(a)
        let req = request(selected.profile, payload: "payload for A")
        let c = coordinator(r, consent: ScriptedConsentBroker(.grantExactly, beforeAnswer: { _ in selected.profile = b }))
        let result = await c.submit(req)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(selected.profile, b, "the app's selection did change mid-consent")
        let call = try XCTUnwrap(r.transport.calls.first)
        XCTAssertEqual(r.transport.calls.count, 1)
        XCTAssertEqual(call.request.profile, a, "the frozen profile went out")
        XCTAssertEqual(call.request.profile.endpoint.host, "api.provider-a.example")
        XCTAssertEqual(call.secret, Data("key-for-A".utf8), "A's key, never B's")
        XCTAssertEqual(call.request.payload, Data("payload for A".utf8))
        XCTAssertEqual(r.ledger.entries().first?.request.endpointHost, "api.provider-a.example")

        // A grant for B's request cannot authorise A's request (and vice versa).
        let r2 = rig()
        try r2.keys.add(Data("key-for-A".utf8), for: a.credentialReference)
        let grantForB = AIConsentGrant(approving: request(b, payload: "payload for A"))
        let crossed = coordinator(r2, consent: ScriptedConsentBroker(.grant(grantForB)))
        let crossedResult = await crossed.submit(request(a, payload: "payload for A"))
        XCTAssertEqual(crossedResult.status, .error(.consentDoesNotCover))
        XCTAssertTrue(r2.transport.calls.isEmpty)
        // Only A's key saved; a request for B finds no key (no borrowing).
        let r3 = rig()
        try r3.keys.add(Data("key-for-A".utf8), for: a.credentialReference)
        let noB = await coordinator(r3, consent: ScriptedConsentBroker(.grantExactly)).submit(request(b))
        XCTAssertEqual(noB.status, .error(.noCredential))
        XCTAssertTrue(r3.transport.calls.isEmpty)
        // Same profile ID, other host: still not A's key.
        let moved = AIProviderProfile(id: a.id, provider: a.provider,
                                      endpoint: AIEndpoint(host: "api.elsewhere.example", ownership: .customerManaged), modelID: a.modelID)
        XCTAssertNil(try r3.keys.read(moved.credentialReference))
    }

    func testSCAF03_grantCoversOnlyTheFrozenRequest_automationNeedsItsOwnGrant() {
        let p = profile()
        let s = sources()
        let req = request(p, payload: "exact payload", sources: s)
        let grant = AIConsentGrant(approving: req)
        XCTAssertTrue(grant.covers(req))
        XCTAssertFalse(grant.covers(request(p, payload: "other payload", sources: s)), "payload changed")
        XCTAssertFalse(grant.covers(request(p, payload: "exact payload")), "source selection changed")
        var otherModel = p; otherModel.modelID = "model-expensive"
        XCTAssertFalse(grant.covers(request(otherModel, payload: "exact payload", sources: s)), "model changed")
        var otherHost = p; otherHost.endpoint = AIEndpoint(host: "api.other.example", ownership: .providerOperated)
        XCTAssertFalse(grant.covers(request(otherHost, payload: "exact payload", sources: s)), "endpoint changed")
        let moreTypes = AISourceSelection(items: s.items, dataTypes: s.dataTypes.union([.attachmentText]))
        XCTAssertFalse(grant.covers(request(p, payload: "exact payload", sources: moreTypes)), "data types changed")
        // B04: automation needs its own grant naming its rule.
        let rule = UUID()
        XCTAssertFalse(grant.covers(request(p, payload: "exact payload", sources: s, trigger: .automation(ruleID: rule))))
        let auto = AIConsentGrant(automationRule: rule, profile: p, purpose: .question, sources: s, spendingAllowance: req.estimate)
        XCTAssertTrue(auto.covers(request(p, payload: "any payload", sources: s, trigger: .automation(ruleID: rule))))
        XCTAssertFalse(auto.covers(request(p, payload: "any payload", sources: s, trigger: .automation(ruleID: UUID()))))
        XCTAssertFalse(auto.covers(request(p, payload: "any payload", sources: s)), "an automation grant is not a user run")
        // Spending allowance: a bigger estimate is not covered; unknown never fits a number.
        let bigger = AIRequest(runID: req.runID, profile: p, purpose: .question, sources: s, payload: Data("exact payload".utf8),
                               promptVersion: "q-1", maxOutputTokens: 100_000, price: price)
        XCTAssertFalse(grant.covers(bigger))
        let unpriced = request(p, payload: "exact payload", sources: s, price: .some(nil))
        XCTAssertFalse(AIConsentGrant(automationRule: rule, profile: p, purpose: .question, sources: s, spendingAllowance: req.estimate)
            .covers(AIRequest(profile: p, purpose: .question, trigger: .automation(ruleID: rule), sources: s,
                              payload: Data("x".utf8), promptVersion: "q-1", maxOutputTokens: 1, price: nil)))
        XCTAssertEqual(unpriced.estimate, .unknown)
    }

    func testSCAF03_B04_savingAKeyStartsNothing() async throws {
        let r = rig()
        let p = profile()
        try r.keys.add(Data("fresh-key".utf8), for: p.credentialReference)
        try r.keys.replace(Data("fresher-key".utf8), for: p.credentialReference)
        XCTAssertEqual(r.grants.activeCount, 0, "a key is not consent")
        XCTAssertTrue(r.transport.calls.isEmpty, "a key is not a request")
        XCTAssertTrue(r.ledger.entries().isEmpty)
        XCTAssertEqual(r.counters.snapshot(), AIScaffoldCounters.Snapshot())
        XCTAssertEqual(r.budget.activeReservations, 0)
    }

    func testSCAF03_consentQueueResolvesExactlyOnce_answerDismissCancelRace() async throws {
        let p = profile()
        // Answer twice.
        let q = AIPendingConsentQueue()
        let req = request(p)
        let t = Task { await q.decide(req) }
        while q.pendingRunIDs.isEmpty { await Task.yield() }
        q.answer(runID: req.runID, .denied)
        q.answer(runID: req.runID, .granted(AIConsentGrant(approving: req)))
        let first = await t.value
        XCTAssertEqual(first, .denied)
        XCTAssertEqual(q.resumedCount, 1)
        XCTAssertEqual(q.ignoredAnswers, 1)
        // Host closed, then a late answer.
        let r2 = request(p)
        let t2 = Task { await q.decide(r2) }
        while q.pendingRunIDs.isEmpty { await Task.yield() }
        q.dismissAll()
        q.answer(runID: r2.runID, .granted(AIConsentGrant(approving: r2)))
        let second = await t2.value
        XCTAssertEqual(second, .cancelled)
        // Task cancelled, then a late answer.
        let r3 = request(p)
        let t3 = Task { await q.decide(r3) }
        while q.pendingRunIDs.isEmpty { await Task.yield() }
        t3.cancel()
        let third = await t3.value
        q.answer(runID: r3.runID, .granted(AIConsentGrant(approving: r3)))
        XCTAssertEqual(third, .cancelled)
        XCTAssertEqual(q.resumedCount, 3)
        XCTAssertTrue(q.pendingRunIDs.isEmpty)
        // Cancelled before it ever waited.
        let r4 = request(p)
        let t4 = Task { () -> AIConsentDecision in
            withUnsafeCurrentTask { $0?.cancel() }
            return await q.decide(r4)
        }
        let fourth = await t4.value
        XCTAssertEqual(fourth, .cancelled)
        XCTAssertEqual(q.resumedCount, 4)

        // Many concurrent requests with racing answers, dismissals and cancellations:
        // every one resumes exactly once (a double resume would trap).
        let n = 60
        let race = AIPendingConsentQueue()
        let reqs = (0..<n).map { _ in request(p) }
        let waiters = reqs.map { r in Task { await race.decide(r) } }
        await withTaskGroup(of: Void.self) { group in
            for (i, r) in reqs.enumerated() {
                let waiter = waiters[i]
                group.addTask {
                    switch i % 3 {
                    case 0: race.answer(runID: r.runID, .denied); race.answer(runID: r.runID, .pending)
                    case 1: race.dismissAll()
                    default: waiter.cancel(); race.answer(runID: r.runID, .denied)
                    }
                }
            }
        }
        // An action that raced ahead of its waiter was ignored; closing the host releases the rest.
        while race.resumedCount < n { race.dismissAll(); await Task.yield() }
        var results: [AIConsentDecision] = []
        for w in waiters { results.append(await w.value) }
        XCTAssertEqual(results.count, n)
        XCTAssertFalse(results.contains(.pending), "a second answer never replaced the first")
        XCTAssertEqual(race.resumedCount, n, "each decide resumed exactly once")
        XCTAssertTrue(race.pendingRunIDs.isEmpty)

        // Through the coordinator: cancel while the sheet is up → zero transport calls.
        let r = rig()
        try r.keys.add(Data("k".utf8), for: p.credentialReference)
        let queue = AIPendingConsentQueue()
        let c = coordinator(r, consent: queue)
        let running = Task { await c.submit(request(p)) }
        while queue.pendingRunIDs.isEmpty { await Task.yield() }
        running.cancel()
        let outcome = await running.value
        XCTAssertEqual(outcome.status, .error(.consentCancelled))
        XCTAssertTrue(r.transport.calls.isEmpty)
        XCTAssertEqual(queue.resumedCount, 1)
    }

    func testSCAF03_unknownPriceIsNotFree_budgetsAndReservations() async throws {
        let unknown = AICostEstimator.estimate(inputTokens: 1000, maxOutputTokens: 100, price: nil)
        XCTAssertEqual(unknown, .unknown)
        XCTAssertFalse(unknown.isFree, "unknown price is not free")
        let partly = AIPriceTable(modelID: "m", inputPerMillionTokens: 1, outputPerMillionTokens: nil, checkedOn: checked)
        XCTAssertEqual(AICostEstimator.estimate(inputTokens: 1, maxOutputTokens: 1, price: partly), .unknown,
                       "a missing output rate is unknown, not zero")
        let zero = AICostEstimate.known(amount: 0, currency: "USD", priceTableDate: checked)
        XCTAssertTrue(zero.isFree)
        XCTAssertFalse(unknown.fits(within: .known(amount: 1_000_000, currency: "USD", priceTableDate: checked)))
        XCTAssertFalse(zero.fits(within: .known(amount: 1, currency: "EUR", priceTableDate: checked)))
        // 1,000 tokens in at $4/M + 512 out at $20/M.
        let est = AICostEstimator.estimate(inputTokens: 1000, maxOutputTokens: 512, price: price)
        XCTAssertEqual(est, .known(amount: Decimal(string: "0.01424")!, currency: "USD", priceTableDate: checked))
        XCTAssertEqual(AITokenEstimator.inputTokens(Data(count: 10)), 4, "rounded up")

        let p = profile()
        // Refused before consent, by default.
        let r = rig()
        try r.keys.add(Data("k".utf8), for: p.credentialReference)
        let consent = ScriptedConsentBroker(.grantExactly)
        let refused = await coordinator(r, consent: consent).submit(request(p, price: .some(nil)))
        XCTAssertEqual(refused.status, .error(.priceUnknown))
        XCTAssertTrue(consent.askedRequests.isEmpty)
        XCTAssertTrue(r.transport.calls.isEmpty)
        // Accepted only when the customer chose to accept unknown pricing, and then only with a matching grant.
        let accepting = rig(budget: AIRunBudget(perRunLimit: 1, periodLimit: 1, acceptsUnknownPrice: true))
        try accepting.keys.add(Data("k".utf8), for: p.credentialReference)
        let ok = await coordinator(accepting, consent: ScriptedConsentBroker(.grantExactly)).submit(request(p, price: .some(nil)))
        XCTAssertEqual(ok.status, .success)

        // Concurrent reservations share the period limit.
        let budget = AIRunBudget(perRunLimit: 1, periodLimit: 1)
        let big = AIRequest(profile: p, purpose: .question, sources: sources(), payload: Data(count: 300_000),
                            promptVersion: "q", maxOutputTokens: 0, price: price)  // 100,000 tokens × $4/M = $0.40
        guard case .reserved(let one) = budget.reserve(big), case .reserved = budget.reserve(big) else {
            return XCTFail("two of $0.40 fit in $1")
        }
        XCTAssertEqual(budget.reserve(big), .refused(.budgetExceeded), "a third would exceed the period")
        budget.release(one)
        guard case .reserved = budget.reserve(big) else { return XCTFail("released space is reusable") }
        let tooBigForOneRun = AIRequest(profile: p, purpose: .question, sources: sources(), payload: Data(count: 900_000),
                                        promptVersion: "q", maxOutputTokens: 0, price: price)  // $1.20
        XCTAssertEqual(AIRunBudget(perRunLimit: 1, periodLimit: 100).reserve(tooBigForOneRun), .refused(.budgetExceeded))
    }

    func testSCAF03_ledgerContract_oneLinePerTransportCall_noSecretNoPayload() async throws {
        let p = profile()
        let r = rig()
        let secret = "sk-test-SECRET-never-in-ledger"
        try r.keys.add(Data(secret.utf8), for: p.credentialReference)
        let c = coordinator(r, consent: ScriptedConsentBroker(.grantExactly))
        let payload = "PAYLOAD-TEXT-never-in-ledger"
        _ = await c.submit(request(p, payload: payload))
        r.transport.setScript(.failure(.provider(message: "timeout")))
        _ = await c.submit(request(p, payload: payload))
        _ = await coordinator(r, consent: ScriptedConsentBroker(.deny)).submit(request(p, payload: payload))
        let entries = r.ledger.entries()
        XCTAssertEqual(entries.count, 2, "the denied request never reached the transport and has no line")
        XCTAssertEqual(entries.map(\.billing), [.reported, .uncertain], "a failed call may still be billable")
        XCTAssertEqual(entries[0].request.payloadSHA256, request(p, payload: payload).payloadSHA256)
        let json = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains(payload))
        XCTAssertEqual(r.budget.activeReservations, 0, "every reservation settled or released")
    }

    func testSCAF03_sourceEligibility_gmailOriginStaysLocal() async throws {
        let p = profile()
        let policy = AISourcePolicy()
        XCTAssertNil(policy.refusal(for: sources([.fileImport]), profile: p))
        XCTAssertEqual(policy.refusal(for: sources([.fileImport, .gmail]), profile: p), .sourceIneligible(origin: .gmail))
        XCTAssertEqual(policy.refusal(for: sources([.unknown]), profile: p), .sourceIneligible(origin: .unknown))
        XCTAssertEqual(policy.refusal(for: sources([.microsoftGraph]), profile: p), .sourceIneligible(origin: .microsoftGraph))
        XCTAssertEqual(AISourcePolicy(allowedOrigins: [.fileImport, .gmail]).refusal(for: sources([.gmail]), profile: p),
                       .sourceIneligible(origin: .gmail), "allowing the origin is not enough without the approved route")
        XCTAssertNil(AISourcePolicy(allowedOrigins: [.gmail], gmailRouteApproved: true).refusal(for: sources([.gmail]), profile: p))
        let r = rig()
        try r.keys.add(Data("k".utf8), for: p.credentialReference)
        let consent = ScriptedConsentBroker(.grantExactly)
        let result = await coordinator(r, consent: consent).submit(request(p, sources: sources([.gmail])))
        XCTAssertEqual(result.status, .error(.sourceIneligible(origin: .gmail)))
        XCTAssertTrue(consent.askedRequests.isEmpty)
        XCTAssertTrue(r.transport.calls.isEmpty)
    }

    // MARK: SCAF-02 / B02 — key profiles in the Keychain

    func testSCAF02_addReplaceRemove_everyStatusSurfaced_failedReplaceKeepsOldKey() throws {
        let keychain = InMemoryAISecretKeychain()
        let store = AIKeyProfileStore(keychain: keychain, useDataProtectionKeychain: false)
        let ref = profile().credentialReference
        XCTAssertNil(try store.read(ref))
        XCTAssertThrowsError(try store.add(Data(), for: ref)) { XCTAssertEqual($0 as? AIKeyStoreError, .emptySecret) }
        try store.add(Data("old-working-key".utf8), for: ref)
        XCTAssertThrowsError(try store.add(Data("other".utf8), for: ref)) { XCTAssertEqual($0 as? AIKeyStoreError, .alreadyExists) }
        XCTAssertEqual(try store.read(ref)?.bytes, Data("old-working-key".utf8), "add never overwrites")

        keychain.updateStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.replace(Data("new-key".utf8), for: ref)) {
            XCTAssertEqual($0 as? AIKeyStoreError, .keychain(operation: .replace, status: errSecInteractionNotAllowed))
            XCTAssertTrue(($0 as? AIKeyStoreError)?.message.contains("\(errSecInteractionNotAllowed)") ?? false)
        }
        keychain.updateStatus = nil
        XCTAssertEqual(try store.read(ref)?.bytes, Data("old-working-key".utf8), "a failed replace keeps the old key")
        try store.replace(Data("new-key".utf8), for: ref)
        XCTAssertEqual(try store.read(ref)?.bytes, Data("new-key".utf8))
        XCTAssertThrowsError(try store.replace(Data("x".utf8), for: profile().credentialReference)) {
            XCTAssertEqual($0 as? AIKeyStoreError, .notFound)
        }

        keychain.addStatus = errSecNotAvailable
        XCTAssertThrowsError(try store.add(Data("k".utf8), for: profile().credentialReference)) {
            XCTAssertEqual($0 as? AIKeyStoreError, .keychain(operation: .add, status: errSecNotAvailable))
        }
        keychain.addStatus = nil
        keychain.readStatus = errSecAuthFailed
        XCTAssertThrowsError(try store.read(ref)) {
            XCTAssertEqual($0 as? AIKeyStoreError, .keychain(operation: .read, status: errSecAuthFailed))
        }
        keychain.readStatus = nil
        keychain.deleteStatus = errSecIO
        XCTAssertThrowsError(try store.remove(ref)) {
            XCTAssertEqual($0 as? AIKeyStoreError, .keychain(operation: .remove, status: errSecIO))
        }
        XCTAssertEqual(try store.read(ref)?.bytes, Data("new-key".utf8), "a failed remove keeps the key")
        keychain.deleteStatus = nil
        XCTAssertTrue(try store.remove(ref))
        XCTAssertFalse(try store.remove(ref), "removing nothing is reported, not an error")
        XCTAssertNil(try store.read(ref))

        // One service, never a mail one; never synchronised; this device only.
        XCTAssertEqual(Set(keychain.queriedServices), [AIKeyProfileStore.service])
        let q = store.query(ref)
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, ref.keychainAccount)
        XCTAssertFalse(ref.keychainAccount.contains("@"), "account-less: profile UUID, provider, host")
    }

    func testSCAF02_secretIsRedactedInEveryTextualForm_andRecordsHoldNoSecret() throws {
        let raw = "sk-live-THIS-MUST-NOT-PRINT"
        let secret = AISecret(Data(raw.utf8))
        var dumped = ""
        dump(secret, to: &dumped)
        for text in ["\(secret)", String(describing: secret), String(reflecting: secret), dumped] {
            XCTAssertFalse(text.contains(raw), text)
            XCTAssertFalse(text.contains("THIS-MUST"), text)
        }
        let p = profile()
        let json = String(decoding: try JSONEncoder().encode([request(p).record]), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode(AIConsentGrant(approving: request(p))), as: UTF8.self)
        XCTAssertFalse(json.contains(raw))
        XCTAssertFalse(json.lowercased().contains("secret"), "no secret field in any persisted shape")
    }

    /// No embedded or default developer key: the scaffold's sources contain no
    /// key-shaped literal and no network API.
    func testSCAF02_noEmbeddedDeveloperKey_noNetworkCode_inScaffoldSources() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ArchiveCore/AIScaffold", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 6)
        let keyShapes = [#"sk-[A-Za-z0-9_\-]{16,}"#, #"sk-ant-[A-Za-z0-9_\-]+"#, #"AIza[0-9A-Za-z_\-]{30,}"#,
                         #"Bearer [A-Za-z0-9]"#, #"x-api-key"#,
                         // Any long token inside a string literal (identifiers such as
                         // kSecAttrAccessibleWhenUnlockedThisDeviceOnly are not literals).
                         #""[A-Za-z0-9_\-+/=]{32,}""#]
        let banned = ["URLSession", "URLRequest", "NWConnection", "import Network", "CFStream", "socket(", "https://"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for shape in keyShapes {
                XCTAssertNil(text.range(of: shape, options: .regularExpression), "\(file.lastPathComponent): \(shape)")
            }
            for word in banned { XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) contains \(word)") }
        }
    }
}
