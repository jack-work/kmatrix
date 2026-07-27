#!/usr/bin/env python3
"""echo — the reference gluck-matrix bot.

It exists to prove the contract end to end. The module hands every bot:

    MATRIX_HOMESERVER        http://127.0.0.1:8008  (loopback, no TLS)
    MATRIX_SERVER_NAME       kelliher.info
    MATRIX_USER_ID           @echo:kelliher.info
    MATRIX_DEVICE_ID         matrix-bot-echo
    MATRIX_ACCESS_TOKEN_FILE path inside the systemd credentials dir
    MATRIX_STORE_DIR         /var/lib/matrix-bot-echo, writable

...and nothing else. No config file, no secret in the environment, no
network reachability beyond what it opens itself.

Behaviour: accepts invites, and replies to `!echo <text>`.
"""

import asyncio
import os
import sys

from nio import AsyncClient, InviteMemberEvent, MatrixRoom, RoomMessageText

HOMESERVER = os.environ["MATRIX_HOMESERVER"]
USER_ID = os.environ["MATRIX_USER_ID"]
DEVICE_ID = os.environ.get("MATRIX_DEVICE_ID", "matrix-bot")
STORE_DIR = os.environ.get("MATRIX_STORE_DIR", "/tmp")


def read_token() -> str:
    path = os.environ["MATRIX_ACCESS_TOKEN_FILE"]
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().strip()


async def main() -> int:
    client = AsyncClient(HOMESERVER, USER_ID, store_path=STORE_DIR)
    client.access_token = read_token()
    client.user_id = USER_ID
    client.device_id = DEVICE_ID

    async def on_invite(room: MatrixRoom, event: InviteMemberEvent) -> None:
        if event.membership != "invite" or event.state_key != USER_ID:
            return
        print(f"joining {room.room_id} (invited by {event.sender})", flush=True)
        await client.join(room.room_id)

    async def on_message(room: MatrixRoom, event: RoomMessageText) -> None:
        if event.sender == USER_ID:
            return
        body = event.body.strip()
        if not body.startswith("!echo"):
            return
        reply = body[len("!echo") :].strip() or "…echo what?"
        await client.room_send(
            room.room_id,
            message_type="m.room.message",
            content={"msgtype": "m.notice", "body": reply},
        )

    client.add_event_callback(on_invite, InviteMemberEvent)
    client.add_event_callback(on_message, RoomMessageText)

    whoami = await client.whoami()
    print(f"connected as {getattr(whoami, 'user_id', whoami)}", flush=True)

    # full_state on first sync so we see rooms we were joined into by the
    # provisioner rather than by an invite we witnessed.
    await client.sync_forever(timeout=30000, full_state=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        sys.exit(0)
