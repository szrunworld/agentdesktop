import AgentDesktopProtocol
import Foundation

// Prompt turns, cancel, approvals and questions (plan §4.6, §4.7, §5.4, §6).
extension ACPAgentServer {
    // MARK: Turn

    func runTurn(sessionId sid: String, turn: ACPPromptTurn, content: [ACPContentBlock]) async {
        let v2 = connection.version == .v2
        // v2: the answer accepts the prompt; the end comes as an update.
        if v2 { await reply(turn.requestId, .promptFinished(.endTurn)) }
        let reason = await turnBody(sid, turn, content)
        if live[sid]?.turn === turn { live[sid]?.turn = nil }
        try? flushCursors(sid)
        guard !closed, !Task.isCancelled else { return }
        if v2 {
            await send(sid, .turnEnded(reason))
        } else {
            await reply(turn.requestId, .promptFinished(reason))
        }
    }

    private func turnBody(_ sid: String, _ turn: ACPPromptTurn, _ content: [ACPContentBlock]) async -> ACPStopReason {
        var texts: [String] = []
        var ignored = 0
        for block in content {
            if case let .text(t) = block { texts.append(t) } else { ignored += 1 }
        }
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        record(sid, .user, text)
        if ignored > 0 { await say(sid, "已忽略 \(ignored) 个附件：目前只接受文字。") }

        if live[sid]?.binding.title == Self.defaultTitle, !text.isEmpty {
            let title = String(redact(sid, text).prefix(80))
            try? persist(sid) { $0.title = title }
        }

        // A question the editor could not show is answered by this prompt.
        if let q = live[sid]?.pendingQuestion, !text.isEmpty, !text.hasPrefix("/") {
            do {
                try await runtime.answer(questionId: q.id, text: text)
            } catch {
                await say(sid, "回答没有送达 Runtime，问题仍在等待。")
                return .endTurn
            }
            live[sid]?.pendingQuestion = nil
            await say(sid, "已提交回答。")
            turn.runId = q.runId
            startFollower(sid, q.runId)
            return await monitor(sid, q.runId, turn)
        }

        var tasksList: [ACPExposedTask] = []
        do { tasksList = try await runtime.tasks() } catch {
            await say(sid, "暂时无法读取可用任务，只能使用 /status、/runs、/cancel。")
        }
        let catalog = ACPCommandCatalog(tasks: tasksList)
        switch catalog.parse(text) {
        case .empty:
            await say(sid, guidance(catalog))
            return .endTurn
        case let .fixed(cmd, argument):
            await runFixed(sid, cmd, argument, catalog)
            return .endTurn
        case let .unknownCommand(name):
            await say(sid, "没有 /\(redact(sid, name)) 这个命令。\n" + guidance(catalog))
            return .endTurn
        case .freeTextNotAllowed:
            await say(sid, "当前没有接受自由文本的任务，未创建任何任务。\n" + guidance(catalog))
            return .endTurn
        case let .ambiguousFreeText(names):
            await say(sid, "有多个任务接受自由文本，请用命令指定：" + names.map { "/\($0)" }.joined(separator: "、") + "。未创建任何任务。")
            return .endTurn
        case let .task(task, argument):
            return await submitTask(sid, turn, task, argument, catalog)
        case let .freeText(task, text):
            return await submitTask(sid, turn, task, text, catalog)
        }
    }

    private func guidance(_ catalog: ACPCommandCatalog) -> String {
        let lines = catalog.commands.map { c in
            "/\(c.name)\(c.inputHint.map { " \($0)" } ?? "")：\(c.description)"
        }
        return "可用命令：\n" + lines.joined(separator: "\n")
    }

    // MARK: Submit

    private func submitTask(_ sid: String, _ turn: ACPPromptTurn, _ task: ACPExposedTask, _ argument: String,
                            _ catalog: ACPCommandCatalog) async -> ACPStopReason {
        let name = catalog.commandName(for: task) ?? task.taskType
        let input: JSONValue
        switch ACPCommandInput.input(argument: argument, schema: task.inputSchema) {
        case let .success(v): input = v
        case .failure(.notJSONObject):
            await say(sid, "/\(name) 的参数不是一个 JSON 对象，未创建任务。")
            return .endTurn
        case let .failure(.needsJSON(hint)):
            await say(sid, "/\(name) 需要 JSON 参数：\(hint)。未创建任务。")
            return .endTurn
        }
        let problems = ACPCommandInputValidator.validate(input, schema: task.inputSchema)
        guard problems.isEmpty else {
            await say(sid, "/\(name) 的输入不符合要求，未创建任务：\n" + problems.joined(separator: "\n"))
            return .endTurn
        }
        guard let options = live[sid]?.binding.options else { return .endTurn }

        // Ask mode adds one editor confirmation before a task that needs
        // approval. It only ever makes things stricter: no answer, a reject
        // or a cancel creates nothing. Auto skips it; the Runtime still
        // applies its own approvals.
        if ACPSessionManagerOptions.mode(options) == .ask, task.requiresApproval {
            let call = ACPToolCall(toolCallId: "acp-submit-\(UUID().uuidString.lowercased())",
                                   title: redact(sid, task.displayName), kind: .execute, status: .pending)
            let outcome = await connection.requestPermission(
                ACPPermissionRequest(sessionId: sid, toolCall: call,
                                     summary: [redact(sid, "将启动任务：\(task.displayName)")]))
            if turn.cancelRequested { return .cancelled }
            guard outcome == .selected(.allowOnce) else {
                await say(sid, "未获批准，未创建任务。")
                return .endTurn
            }
        }
        if turn.cancelRequested { return .cancelled }

        let material = "\(task.taskType)\n\(input.encoded())"
        let key = await submissionKey(sid, material: material, taskType: task.taskType, input: input)
        live[sid]?.lastSubmission = (material, key, nil)
        // Write-ahead: the key is on disk before the request leaves, so a
        // retry after a restart still finds it (and, unconfirmed, reuses it:
        // the same prompt at the same position derives the same key).
        do {
            try persist(sid) { $0.pendingSubmissionKey = key }
        } catch {
            await say(sid, "会话绑定无法保存，未提交任务。")
            return .endTurn
        }

        let receipt: ACPSubmissionReceipt
        do {
            receipt = try await runtime.submit(ACPSubmission(submissionKey: key, acpSessionId: sid, taskType: task.taskType,
                                                             input: input, desktopId: nil))
        } catch let e as ACPError where !Self.stateUnknown(e) {
            // A definite runtime/1 error (e.g. capability_missing before
            // unit.run exists): nothing was started.
            receipt = .refused(code: e.reason, message: e.message)
        } catch {
            // timeout / connection_lost / anything else: whether it reached
            // the Runtime is not known, same as unconfirmed.
            receipt = .unconfirmed
        }

        switch receipt {
        case let .accepted(snap), let .duplicate(snap):
            let runId = snap.runId
            try? persist(sid) { b in
                if !b.runIds.contains(runId) { b.runIds.append(runId) }
                if b.pendingSubmissionKey == key { b.pendingSubmissionKey = nil }
            }
            if live[sid]?.lastSubmission?.key == key { live[sid]?.lastSubmission?.runId = runId }
            turn.runId = runId
            if case .duplicate = receipt {
                await say(sid, "这是同一条请求的重试，继续显示原任务 \(runId)（没有新建任务）。", runId: runId)
            } else {
                await say(sid, "任务已受理：\(runId)（\(redact(sid, task.displayName))）。", runId: runId)
            }
            startFollower(sid, runId)
            // A cancel that arrived before the runId was known is sent now,
            // exactly once.
            if turn.cancelRequested, !turn.cancelSent {
                turn.cancelSent = true
                await requestCancel(sid, runId)
            }
            return await monitor(sid, runId, turn)
        case let .refused(code, message):
            live[sid]?.lastSubmission = nil
            try? persist(sid) { b in if b.pendingSubmissionKey == key { b.pendingSubmissionKey = nil } }
            await say(sid, "Runtime 拒绝了这个任务（\(redact(sid, code))）：\(redact(sid, message))")
            return .refusal
        case .unconfirmed:
            // Never resent from here. Repeating the same prompt carries the
            // same key, so the Runtime's ledger answers with the original.
            await say(sid, "提交结果待核实：没有收到 Runtime 的确认，也不会自动重发。可以用 /status 查看；原样重发这条 prompt 会使用同一个提交键，只会查询原请求，不会重复执行。")
            return .endTurn
        }
    }

    /// `ACPRuntimePort` error rule: these reasons (and any non-ACPError)
    /// mean the state is unknown — query again, never treat as definite.
    static func stateUnknown(_ e: ACPError) -> Bool {
        ["timeout", "connection_lost", "internal_error"].contains(e.reason)
    }

    static func isCapabilityMissing(_ error: Error) -> Bool {
        (error as? ACPError)?.reason == "capability_missing"
    }

    /// Same prompt again while the last one is unconfirmed or its Run is
    /// still open → the same key. Otherwise a new key for the next position.
    private func submissionKey(_ sid: String, material: String, taskType: String, input: JSONValue) async -> String {
        if let last = live[sid]?.lastSubmission, last.material == material {
            guard let runId = last.runId else { return last.key }
            if let snap = try? await runtime.snapshot(runId: runId), snap.phase != "ended" { return last.key }
        }
        let ordinal = live[sid]?.binding.runIds.count ?? 0
        return ACPPromptSubmissionKey.make(sessionId: sid, ordinal: ordinal, taskType: taskType, input: input)
    }

    // MARK: Monitor

    /// Keep the turn open while the Run is active. Ends at the Run's end,
    /// at a stop the Runtime confirmed, when a decision cannot be made in
    /// the editor, or after the hold time.
    func monitor(_ sid: String, _ runId: String, _ turn: ACPPromptTurn) async -> ACPStopReason {
        let clock = ContinuousClock()
        let start = clock.now
        var unreadableSaid = false
        while true {
            if Task.isCancelled || closed { return .cancelled }
            if live[sid] == nil || turn.closing { return .endTurn }
            if let snap = try? await runtime.snapshot(runId: runId) {
                if snap.phase == "ended" {
                    await drain(sid, runId, timeout: config.drainTimeout)
                    await say(sid, "任务 \(runId) 已结束：\(Self.describe(snap))")
                    return (turn.cancelRequested || snap.outcome == "cancelled") ? .cancelled : .endTurn
                }
                if turn.cancelRequested {
                    if snap.quiescence == "confirmed" {
                        await say(sid, "任务 \(runId) 已停止输入（Runtime 已确认静止）。")
                        return .cancelled
                    }
                } else if snap.phase == "waiting_approval" || snap.phase == "waiting_input" {
                    if await handlePending(sid, runId, turn) { return .endTurn }
                }
            } else if !unreadableSaid {
                unreadableSaid = true
                await say(sid, "任务 \(runId) 的状态暂时无法读取，继续等待。")
            }
            if clock.now - start >= config.holdTime {
                await say(sid, "本轮已等待较长时间，先结束这一轮；任务 \(runId) 的后续更新会继续在本会话中显示（不在本轮内），也可以用 /status 查看。")
                return .endTurn
            }
            do { try await Task.sleep(for: config.pollInterval) } catch { return .cancelled }
        }
    }

    // MARK: Approvals and questions

    /// Returns true when the turn has to end because the decision cannot be
    /// made in the editor.
    private func handlePending(_ sid: String, _ runId: String, _ turn: ACPPromptTurn) async -> Bool {
        let decisions: [ACPPendingDecision]
        do {
            decisions = try await runtime.pending(runId: runId)
        } catch let e as ACPError where Self.stateUnknown(e) {
            // Unknown, not absent: ask again on the next poll.
            if !turn.pendingUnknownSaid {
                turn.pendingUnknownSaid = true
                await say(sid, "暂时读不到任务 \(runId) 的待处理事项，继续查询。")
            }
            return false
        } catch {
            // capability_missing (docs/acp/README.md §2.5) or another definite
            // error: no approval channel. Never an allow; the Run keeps waiting.
            await say(sid, "任务 \(runId) 在等待审批或输入，但当前 Runtime 没有可用的审批通道（不会当作批准）。请在 AgentDesktop 主窗口处理，或用 /cancel 停止。")
            return true
        }
        for d in decisions {
            switch d {
            case let .approval(id, _, toolCall, summary):
                guard live[sid]?.handledDecisions.contains(id) == false else { continue }
                live[sid]?.handledDecisions.insert(id)
                guard let options = live[sid]?.binding.options else { return true }
                if ACPSessionManagerOptions.mode(options) == .auto {
                    // Auto never approves on the user's behalf.
                    await say(sid, "任务 \(runId) 有一步需要审批。Auto 模式不在编辑器里追加确认，也不会代为批准；请在 AgentDesktop 主窗口审批。")
                    return true
                }
                var call = toolCall
                call.title = redact(sid, call.title)
                call.detail = call.detail.map { redact(sid, $0) }
                turn.inFlightApprovals.insert(id)
                let outcome = await connection.requestPermission(
                    ACPPermissionRequest(sessionId: sid, toolCall: call, summary: summary.map { redact(sid, $0) }))
                turn.inFlightApprovals.remove(id)
                if turn.decided.contains(id) { continue } // a cancel already denied it
                turn.decided.insert(id)
                let allow = outcome == .selected(.allowOnce) && !turn.cancelRequested
                do {
                    try await runtime.decide(approvalId: id, allow: allow)
                    await say(sid, allow ? "已批准这一次。" : "已拒绝。")
                } catch {
                    await say(sid, "决定没有送达 Runtime；没有送达的决定不会被当作批准。")
                }
            case let .question(id, _, message, choices):
                guard live[sid]?.handledDecisions.contains(id) == false else { continue }
                live[sid]?.handledDecisions.insert(id)
                let shown = redact(sid, message)
                let answer = await connection.ask(ACPQuestion(sessionId: sid, message: shown,
                                                              choices: choices.map { redact(sid, $0) }))
                switch answer {
                case let .answered(text):
                    do {
                        try await runtime.answer(questionId: id, text: text)
                        continue
                    } catch {}
                case .declined:
                    do {
                        try await runtime.decline(questionId: id)
                        await say(sid, "已告知 Runtime：不回答这个问题。")
                        continue
                    } catch {
                        // capability_missing: the Runtime cannot record a
                        // decline yet; the question stays open for a prompt.
                    }
                case .unavailable:
                    break
                }
                live[sid]?.pendingQuestion = (id, runId)
                await say(sid, "任务 \(runId) 需要你的回答：\(shown)\n请在下一条 prompt 里直接回答。")
                return true
            }
        }
        return false
    }

    // MARK: Cancel

    /// `session/cancel`: mark the turn, deny every permission request still
    /// open, and send the cancel intent. The turn ends `cancelled` only
    /// once the Runtime confirms quiescence or the Run ended.
    func cancelTurn(sessionId sid: String) {
        guard let turn = live[sid]?.turn, !turn.cancelRequested else { return }
        turn.cancelRequested = true
        let open = turn.inFlightApprovals.subtracting(turn.decided)
        turn.decided.formUnion(open)
        let runId = turn.runId
        if runId != nil { turn.cancelSent = true }
        spawn {
            for id in open { try? await self.runtime.decide(approvalId: id, allow: false) }
            if let runId { await self.requestCancel(sid, runId) }
        }
    }

    func requestCancel(_ sid: String, _ runId: String) async {
        do {
            let snap = try await runtime.cancel(runId: runId, requestId: "acp-cancel-\(sid)-\(runId)")
            await say(sid, "正在停止任务 \(runId)：\(Self.describe(snap))")
        } catch {
            await say(sid, "停止请求没有得到确认，正在查询任务 \(runId) 的状态。")
        }
    }

    // MARK: Fixed commands

    private func runFixed(_ sid: String, _ cmd: ACPCommandFixed, _ argument: String, _ catalog: ACPCommandCatalog) async {
        let runIds = live[sid]?.binding.runIds ?? []
        let arg = argument.trimmingCharacters(in: .whitespaces)
        if !arg.isEmpty, cmd == .status || cmd == .cancel, !runIds.contains(arg) {
            await say(sid, "本会话没有这个任务。")
            return
        }
        switch cmd {
        case .help:
            await say(sid, guidance(catalog))
        case .runs, .status:
            let targets = arg.isEmpty ? Array(runIds.suffix(20)) : [arg]
            if targets.isEmpty { await say(sid, "本会话还没有任务。"); return }
            var lines: [String] = []
            for id in targets {
                if let s = try? await runtime.snapshot(runId: id) {
                    lines.append("\(id)：\(Self.describe(s))")
                } else {
                    lines.append("\(id)：状态待核实（不会自动重试）")
                }
            }
            await say(sid, lines.joined(separator: "\n"))
        case .cancel:
            var targets: [String] = []
            for id in (arg.isEmpty ? runIds : [arg]) {
                if let s = try? await runtime.snapshot(runId: id), s.phase == "ended" { continue }
                targets.append(id)
            }
            if targets.isEmpty { await say(sid, "本会话没有在运行的任务。"); return }
            for id in targets { await requestCancel(sid, id) }
        }
    }
}
