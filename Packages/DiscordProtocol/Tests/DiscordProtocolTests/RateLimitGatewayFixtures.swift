@testable import DiscordProtocol

func startupUnreadReadyMessage() -> GatewaySocketMessage {
    gatewayMessage(
        op: 0,
        data: .object([
            "session_id": .string("startup-unread-session"),
            "resume_gateway_url": .string("wss://gateway.discord.gg"),
            "user_settings_proto": .object(["future_shape": .bool(true)]),
            "merged_members": .object(["future_shape": .bool(true)]),
            "guilds": .array([
                .object([
                    "id": .string("100"),
                    "voice_states": .object(["future_shape": .bool(true)]),
                    "channels": .array([
                        .object([
                            "id": .string("201"),
                            "guild_id": .string("100"),
                            "name": .string("raw-store-first"),
                            "type": .number(0),
                            "position": .number(10),
                            "permission_overwrites": .array([]),
                        ]),
                        .object([
                            "id": .string("200"),
                            "guild_id": .string("100"),
                            "name": .string("general"),
                            "type": .number(0),
                            "position": .number(0),
                            "last_message_id": .string("300"),
                            "permission_overwrites": .array([]),
                        ])
                    ]),
                ])
            ]),
            "read_state": .object([
                "version": .number(61),
                "entries": .array([
                    .object([
                        "id": .string("200"),
                        "read_state_type": .number(0),
                        "last_message_id": .string("250"),
                        "mention_count": .number(2),
                    ])
                ]),
            ]),
            "user_guild_settings": .object([
                "entries": .array([
                    .object([
                        "guild_id": .string("100"),
                        "message_notifications": .number(1),
                        "muted": .object(["future_shape": .bool(true)]),
                        "flags": .number(2048),
                        "channel_overrides": .array([
                            .object([
                                "channel_id": .string("200"),
                                "message_notifications": .number(1),
                                "flags": .number(1024),
                            ])
                        ]),
                    ])
                ]),
                "partial": .bool(false),
            ]),
            "notification_settings": .object([
                "flags": .number(0)
            ]),
        ]),
        sequence: 1,
        eventName: "READY"
    )
}
