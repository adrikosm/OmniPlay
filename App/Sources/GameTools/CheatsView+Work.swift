import GameStore
import GameTools
import RuntimeCore
import SwiftUI

extension CheatsView {
    // MARK: Work

    func readRoster() async {
        guard tools.capabilities.contains(.actors), !readingRoster else { return }
        readingRoster = true
        defer { readingRoster = false }
        do {
            let page = try await tools.list(.actors, query: nil, page: StatePage(size: 1000))
            var members: [RosterMember] = []
            var found: Set<ActorStat> = []
            for entry in page.entries {
                guard case let .actorProperty(id, property) = entry.target else { continue }
                if let stat = ActorStat(property) {
                    found.insert(stat)
                }
                known[entry.target] = entry.value
                guard !members.contains(where: { $0.id == id }) else { continue }
                let name = try? await tools.read(.actorProperty(actorID: id, .name))
                if case let .string(text) = name, !text.isEmpty {
                    members.append(RosterMember(id: id, name: text))
                } else {
                    members.append(RosterMember(id: id, name: "Character \(id)"))
                }
            }
            if tools.capabilities.contains(.patches), !members.isEmpty {
                found.insert(.godMode)
            }
            roster = members
            // An empty party still gets its headers, so the rows can say why nothing is there.
            stats = found.isEmpty ? defaultStats : ActorStat.allCases.filter(found.contains)
            rosterProblem = nil
        } catch {
            stats = defaultStats
            rosterProblem = "The party is not available yet. Resume the game, then try again."
        }
    }

    var defaultStats: [ActorStat] {
        tools.capabilities.contains(.patches) ? [.godMode, .hp, .mp, .level, .exp] : [.hp, .mp, .level, .exp]
    }

    func warnedKey(_ cheat: CheatDefinition) -> String { "cheats.warned.\(game.id.rawValue.uuidString).\(cheat.id)" }

    func run(_ cheat: CheatDefinition, parameters: [String: Int]) async {
        guard !catalogWorking else { return }
        // An enabled switch can always be turned off without repeating its first-use warning.
        var turningOn = true
        if cheat.isToggle, let target = cheat.steps.first?.resolvedTarget(parameters),
           case .bool(true) = try? await tools.read(target) {
            turningOn = false
        }
        if turningOn, cheat.warning != nil, !UserDefaults.standard.bool(forKey: warnedKey(cheat)) {
            pendingWarning = (cheat, parameters)
            return
        }
        await perform(cheat, parameters: parameters)
    }

    func perform(_ cheat: CheatDefinition, parameters: [String: Int]) async {
        guard !catalogWorking else { return }
        catalogWorking = true
        defer { catalogWorking = false }
        let before = Set(tools.records.map(\.id))
        let outcome = await CheatRunner.run(cheat, parameters: parameters, with: tools)
        let added = tools.records.filter { !before.contains($0.id) }.map(\.id)
        if !added.isEmpty {
            lastRun = (cheat.name, added)
        }
        if outcome.applied {
            failed.remove(cheat.id)
            messages[cheat.id] = outcome.message ?? "Applied to the game."
        } else {
            failed.insert(cheat.id)
            messages[cheat.id] = outcome.message ?? "The game did not accept this right now."
        }
        undoProblem = nil
        revision += 1
    }

    func undo() async {
        guard !undoing, let last = tools.records.last else { return }
        undoing = true
        defer { undoing = false }
        let ids = lastRun?.records.last == last.id ? lastRun?.records ?? [last.id] : [last.id]
        for id in ids.reversed() {
            guard tools.records.last?.id == id, let result = await tools.undo() else { break }
            if result.result == .rejected {
                undoProblem = result.validation.first?.message ?? "The game could not undo this change."
                revision += 1
                return
            }
        }
        lastRun = nil
        undoProblem = nil
        revision += 1
    }
}
