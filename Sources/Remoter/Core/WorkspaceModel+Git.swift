import AppKit

// Операции git на сервере: stage/unstage, commit, discard — всё разрушающее спрашивает
// подтверждение словами «что именно будет потеряно», а не «вы уверены?».

extension WorkspaceModel {

    func stage(_ c: GitChange) async { await gitOp { try await Git.stage(conn: self.conn, root: $0, change: c) } }
    func unstage(_ c: GitChange) async { await gitOp { try await Git.unstage(conn: self.conn, root: $0, change: c) } }

    func discard(_ c: GitChange) async {
        guard canWrite else {
            errorMessage = WriteError.readOnlyWorkspace.localizedDescription
            return
        }
        let alert = NSAlert()
        alert.messageText = "Отбросить изменения в \(c.name)?"
        alert.informativeText = c.kind == .untracked
            ? "Файл будет удалён с сервера безвозвратно."
            : "Файл вернётся к версии из последнего коммита. Отменить это будет нельзя."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Отменить")
        alert.addButton(withTitle: "Отбросить")
        guard alert.runModal() != .alertFirstButtonReturn else { return }

        await gitOp { try await Git.discard(conn: self.conn, root: $0, change: c) }
        if doc?.relPath == c.path {
            doc = nil
            monaco.showMessage("Изменения отброшены")
        }
    }

    func commit(message: String) async {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await gitOp { try await Git.commit(conn: self.conn, root: $0, message: message) }
    }

    func stageAll() async {
        await gitOp { try await self.conn.shOK("git -C \(shq($0)) add -A") }
    }

    func unstageAll() async {
        await gitOp {
            // В репозитории без единого коммита HEAD ещё не существует — `reset HEAD` там не работает.
            let script = """
            cd \(shq($0)) || exit 1
            if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
              git reset -q HEAD
            else
              git rm -q -r --cached .
            fi
            """
            try await self.conn.shOK(script)
        }
    }

    /// Отбросить ВСЕ правки в рабочей копии. Спрашиваем — и не «вы уверены?», а сколько файлов
    /// и что именно будет потеряно: это `git checkout --`, отменить его нечем.
    func discardAll(_ changes: [GitChange]) async {
        guard canWrite, !changes.isEmpty else { return }

        let untracked = changes.filter { $0.worktreeKind == .untracked }
        let tracked = changes.filter { $0.worktreeKind != nil && $0.worktreeKind != .untracked }

        let alert = NSAlert()
        alert.messageText = "Отбросить изменения в \(changes.count) файлах?"
        alert.informativeText = [
            tracked.isEmpty ? nil : "\(tracked.count) вернутся к версии из индекса.",
            untracked.isEmpty ? nil : "\(untracked.count) новых будут удалены с сервера безвозвратно.",
            "Отменить это будет нельзя.",
        ].compactMap { $0 }.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Отменить")
        alert.addButton(withTitle: "Отбросить")
        guard alert.runModal() != .alertFirstButtonReturn else { return }

        guard let root = repoRoot else { return }
        beginBusy()
        defer { endBusy() }

        // Один refresh на всю пачку, а не по одному на файл: gitOp после каждой операции
        // дёргал бы полный `git status` — на полусотне файлов это полсотни лишних раундтрипов.
        for change in changes {
            do {
                try await Git.discard(conn: conn, root: root, change: change)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await refresh(force: true)
    }

    private func gitOp(_ op: @escaping (String) async throws -> Void) async {
        guard let root = repoRoot else { return }
        guard canWrite else {
            errorMessage = WriteError.readOnlyWorkspace.localizedDescription
            return
        }
        beginBusy()
        defer { endBusy() }
        do {
            try await op(root)
            await refresh(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
