import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func handleGatewayInteractionEvent(
        name: String,
        body: JSONValue
    ) async -> Bool {
        switch name {
        case "GUILD_APPLICATION_COMMAND_INDEX_UPDATE":
            await handleGuildApplicationCommandIndexUpdateDispatch(name: name, body: body)
        case "RATE_LIMITED":
            await handleRateLimitedDispatch(name: name, body: body)
        case "USER_APPLICATION_UPDATE", "USER_APPLICATION_REMOVE":
            await handleUserApplicationUpdateDispatch(name: name, body: body)
        case "APPLICATION_COMMAND_AUTOCOMPLETE_RESPONSE":
            await handleApplicationCommandAutocompleteResponseDispatch(name: name, body: body)
        case "INTERACTION_CREATE":
            await handleInteractionCreateDispatch(name: name, body: body)
        case "INTERACTION_SUCCESS":
            await handleInteractionSuccessDispatch(name: name, body: body)
        case "INTERACTION_FAILURE":
            await handleInteractionFailureDispatch(name: name, body: body)
        case "INTERACTION_MODAL_CREATE":
            await handleInteractionModalCreateDispatch(name: name, body: body)
        default:
            return false
        }
        return true
    }

    func handleGuildApplicationCommandIndexUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let update = try? JSONValueDecoder().decode(
                GatewayApplicationCommandIndexUpdateDTO.self, from: body
            ), let guildID = GuildID(update.guildID)
        else { return }
        let target = ApplicationCommandIndexTarget.guild(guildID)
        if cachedApplicationCommandCatalogs[target]?.version != update.version?.value {
            invalidateApplicationCommandCatalog(target)
        }
    }

    func handleRateLimitedDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let rateLimit = try? JSONValueDecoder().decode(
            GatewayRateLimitedDTO.self, from: body
        ) else { return }
        gatewayOpcodeRateLimitDates[rateLimit.opcode] = Date().addingTimeInterval(
            max(0, rateLimit.retryAfter)
        )
        failGatewayRequests(rateLimited: rateLimit)
        if rateLimit.opcode == 3 {
            lastSentPresenceStatus = nil
            lastSentActivities = nil
            await sendPresenceIfChanged()
        }
    }

    func handleUserApplicationUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        invalidateApplicationCommandCatalog(.user)
    }

    func handleApplicationCommandAutocompleteResponseDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let response = try? JSONValueDecoder().decode(
                GatewayApplicationCommandAutocompleteDTO.self, from: body
            )
        else { return }
        let nonce = response.nonce.value
        // The type outlives the local deadline so late choices still reach a
        // draft that is waiting for this exact nonce.
        guard let optionType = autocompleteOptionTypes[nonce] else { return }
        forgetAutocomplete(nonce: nonce)
        let choices = response.choices.compactMap { $0.domain(optionType: optionType) }
        continuation?.yield(
            .applicationCommandAutocomplete(
                ApplicationCommandAutocompleteResult(nonce: nonce, choices: choices)
            )
        )
    }

    func handleInteractionCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let event = try? JSONValueDecoder().decode(
                GatewayInteractionLifecycleDTO.self, from: body),
            let nonce = event.nonce?.value, let interactionID = event.id
        else { return }
        continuation?.yield(
            .interaction(.created(nonce: nonce, interactionID: interactionID))
        )
    }

    func handleInteractionSuccessDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let event = try? JSONValueDecoder().decode(
                GatewayInteractionLifecycleDTO.self, from: body),
            let nonce = event.nonce?.value
        else { return }
        // Autocomplete success can precede its choices and is not a result.
        guard autocompleteOptionTypes[nonce] == nil else { return }
        continuation?.yield(.interaction(.succeeded(nonce: nonce, interactionID: event.id)))
    }

    func handleInteractionFailureDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let event = try? JSONValueDecoder().decode(
                GatewayInteractionLifecycleDTO.self, from: body),
            let nonce = event.nonce?.value
        else { return }
        autocompleteTimeoutTasks.removeValue(forKey: nonce)?.cancel()
        continuation?.yield(.interaction(.failed(nonce: nonce, failure: event.failure)))
    }

    func handleInteractionModalCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let event = try? JSONValueDecoder().decode(
                GatewayInteractionModalDTO.self, from: body
            )
        else { return }
        let context = event.nonce.flatMap { pendingInteractionContexts[$0.value] }
        guard let modal = event.modal(invocationGuildID: context?.guildID) else { return }
        continuation?.yield(.interaction(.presentModal(modal)))
    }
}
