import Foundation
import SakuraCordModels

/// Discord's client-side built-in slash commands, as the official client lists
/// them (definitions transcribed from Discord desktop build 2026-10-04). They
/// never reach an application; SakuraCord runs each one natively.
enum DiscordBuiltInCommands {
    /// Discord's built-in section, which sorts after every application.
    static let application = ApplicationCommandApplication(id: "-1", name: "Built-in")

    // Official client local identity (user 1), not a remotely fetchable account.
    // Avatar: discord.com/assets/9380e4b5bd8d267c.png, verified 2026-10-05.
    static let clyde = User(
        id: UserID(rawValue: 1), username: "Clyde", discriminator: "0000",
        displayName: "Clyde",
        avatarURL: Bundle.module.url(forResource: "DiscordClyde", withExtension: "png"),
        isBot: true
    )
    static let clydeAccent: UInt32 = 0x5C64F3

    static func isClydeMessage(_ message: Message) -> Bool {
        message.application?.id == application.id
            && message.flags.contains(.ephemeral)
            && message.author.id == clyde.id
    }

    /// What a built-in's availability depends on in the current conversation.
    struct Context {
        var isPrivate: Bool
        var isGroupDirectMessage: Bool
        /// Effective permissions in the channel; nil when unknown.
        var channelPermissions: UInt64?
        /// Guild-level permissions; nil outside a guild or when unknown.
        var guildPermissions: UInt64?
        var canCreatePublicThread: Bool
        /// Discord's "Allow playback and usage of /tts command" setting.
        var allowsTTSCommand: Bool
    }

    /// Discord's built-in list order: integrations and conversation tools first.
    static let all: [ApplicationCommand] = [
        command("-16", "gif", "Search Animated GIFs on the Web", options: [
            option("-16", "query", .string, "Search for a GIF", required: true)
        ]),
        command("-15", "leave", "Leave Group", options: [
            option("-15", "silent", .boolean, "Leave without notifying other members", required: false)
        ]),
        command("-19", "schedule", "Schedule a message to send later", options: [
            option("-19", "message", .string, "The message to send", required: true)
        ]),
        command("-17", "sticker", "Search your stickers", options: [
            option("-17", "query", .string, "Search for a sticker", required: true)
        ]),
        command("-1", "shrug", "Appends ¯\\_(ツ)_/¯ to your message.", options: [
            option("-1", "message", .string, "Your message", required: false)
        ]),
        command("-2", "tableflip", "Appends (╯°□°)╯︵ ┻━┻ to your message.", options: [
            option("-2", "message", .string, "Your message", required: false)
        ]),
        command("-3", "unflip", "Appends ┬─┬ ノ( ゜-゜ノ) to your message.", options: [
            option("-3", "message", .string, "Your message", required: false)
        ]),
        command("-4", "tts", "Use text-to-speech to read the message to all members currently viewing the channel.", options: [
            option("-4", "message", .string, "Your message", required: true)
        ]),
        command("-5", "me", "Displays text with emphasis.", options: [
            option("-5", "message", .string, "Your message", required: true)
        ]),
        command("-6", "spoiler", "Marks your message as a spoiler.", options: [
            option("-6", "message", .string, "Your message", required: true)
        ]),
        command("-7", "nick", "Change nickname on this server.", options: [
            option("-7", "new_nick", .string, "New nickname", required: false, maximumLength: 32)
        ]),
        command("-10", "thread", "Start new thread", options: [
            option("-10", "name", .string, "Type a name for your thread", required: true),
            option("-10", "message", .string, "Type the first message in your thread", required: true)
        ]),
        command("-11", "kick", "Kick user", options: [
            option("-11", "user", .user, "The user to kick", required: true),
            option("-11", "reason", .string, "The reason for kicking, if any", required: false)
        ]),
        command("-12", "ban", "Ban user", options: [
            option("-12", "user", .user, "The user to ban", required: true),
            option("-12", "delete_messages", .integer, "How much of their recent message history to delete", required: true,
                choices: [
                    choice("Don't Delete Any", 0), choice("Previous Hour", 3600), choice("Previous 6 Hours", 21600),
                    choice("Previous 12 Hours", 43200), choice("Previous 24 Hours", 86400),
                    choice("Previous 3 Days", 259200), choice("Previous 7 Days", 604800),
                ]),
            option("-12", "reason", .string, "The reason for banning, if any", required: false)
        ]),
        command("-13", "timeout", "Time out user", options: [
            option("-13", "user", .user, "The user to time out", required: true),
            option("-13", "duration", .integer, "How long they should be timed out for", required: true,
                choices: [choice("60 secs", 60), choice("5 mins", 300), choice("10 mins", 600), choice("1 hour", 3600), choice("1 day", 86400), choice("1 week", 604800)]),
            option("-13", "reason", .string, "The reason for timing them out, if any", required: false)
        ]),
        command("-14", "msg", "Message user", options: [
            option("-14", "user", .user, "The user to message", required: true),
            option("-14", "message", .string, "Message to send", required: true)
        ])
    ]

    /// The built-ins Discord offers in this conversation.
    static func available(in context: Context) -> [ApplicationCommand] {
        all.filter { isAvailable($0, in: context) }
    }

    static func isAvailable(_ command: ApplicationCommand, in context: Context) -> Bool {
        func can(_ permission: UInt64, _ permissions: UInt64?) -> Bool {
            guard let permissions else { return false }
            return permissions & DiscordPermissionBits.administrator != 0 || permissions & permission != 0
        }
        return switch command.name {
        case "leave": context.isGroupDirectMessage
        // Discord gates /schedule behind an experiment this account is not in.
        case "schedule": false
        case "tts":
            !context.isPrivate && context.allowsTTSCommand
                && can(DiscordPermissionBits.sendTTSMessages, context.channelPermissions)
        case "nick":
            !context.isPrivate && (can(DiscordPermissionBits.changeNickname, context.channelPermissions)
                || can(DiscordPermissionBits.manageNicknames, context.channelPermissions))
        case "thread": context.canCreatePublicThread
        case "kick": can(DiscordPermissionBits.kickMembers, context.guildPermissions)
        case "ban": can(DiscordPermissionBits.banMembers, context.guildPermissions)
        case "timeout": can(DiscordPermissionBits.moderateMembers, context.guildPermissions)
        default: true
        }
    }

    static func isBuiltIn(_ command: ApplicationCommand) -> Bool {
        command.applicationID == application.id
    }

    private static func command(
        _ id: String, _ name: String, _ description: String, options: [ApplicationCommandOption]
    ) -> ApplicationCommand {
        ApplicationCommand(
            id: id, rootCommandID: id, applicationID: application.id, version: "0", name: name,
            description: description, application: application, options: options
        )
    }

    private static func option(
        _ commandID: String, _ name: String, _ type: ApplicationCommandOptionType, _ description: String,
        required: Bool, choices: [ApplicationCommandChoice] = [], maximumLength: Int? = nil
    ) -> ApplicationCommandOption {
        ApplicationCommandOption(
            id: "\(commandID)/\(name)", name: name, description: description, type: type,
            isRequired: required, choices: choices, maximumLength: maximumLength
        )
    }

    private static func choice(_ name: String, _ value: Int64) -> ApplicationCommandChoice {
        ApplicationCommandChoice(name: name, value: .integer(value))
    }
}
