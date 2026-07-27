// echo — the reference kmatrix bot.
//
// It exists to prove the contract end to end. The module hands every bot:
//
//	MATRIX_HOMESERVER        http://127.0.0.1:8008  (loopback, no TLS)
//	MATRIX_SERVER_NAME       kelliher.info
//	MATRIX_USER_ID           @echo:kelliher.info
//	MATRIX_DEVICE_ID         kmatrix-bot-echo
//	MATRIX_ACCESS_TOKEN_FILE a path inside $CREDENTIALS_DIRECTORY
//	MATRIX_STORE_DIR         /var/lib/kmatrix-bot-echo, writable
//
// ...and nothing else. No config file, no secret in the environment, no
// network reachability beyond what it opens itself.
//
// Behaviour:
//   - accepts every invite,
//   - "!ping"        → "pong",
//   - "!echo <text>" → "<text>",
//   - in a two-person room, echoes anything else you say.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

func env(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("%s is not set — is this running under the kmatrix module?", key)
	}
	return v
}

func main() {
	homeserver := env("MATRIX_HOMESERVER")
	userID := id.UserID(env("MATRIX_USER_ID"))

	raw, err := os.ReadFile(env("MATRIX_ACCESS_TOKEN_FILE"))
	if err != nil {
		log.Fatalf("reading access token: %v", err)
	}

	client, err := mautrix.NewClient(homeserver, userID, strings.TrimSpace(string(raw)))
	if err != nil {
		log.Fatalf("creating client: %v", err)
	}
	client.DeviceID = id.DeviceID(os.Getenv("MATRIX_DEVICE_ID"))

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	whoami, err := client.Whoami(ctx)
	if err != nil {
		log.Fatalf("whoami: %v", err)
	}
	log.Printf("connected as %s", whoami.UserID)

	// Anything older than startup is history, not a command. Without this
	// the bot re-answers every message in every room each time it restarts.
	startedAt := time.Now()

	syncer, ok := client.Syncer.(*mautrix.DefaultSyncer)
	if !ok {
		log.Fatal("unexpected syncer type")
	}

	syncer.OnEventType(event.StateMember, func(ctx context.Context, evt *event.Event) {
		if evt.GetStateKey() != string(userID) {
			return
		}
		if evt.Content.AsMember().Membership != event.MembershipInvite {
			return
		}
		log.Printf("joining %s (invited by %s)", evt.RoomID, evt.Sender)
		if _, err := client.JoinRoomByID(ctx, evt.RoomID); err != nil {
			log.Printf("warn: could not join %s: %v", evt.RoomID, err)
		}
	})

	syncer.OnEventType(event.EventMessage, func(ctx context.Context, evt *event.Event) {
		if evt.Sender == userID || evt.Timestamp < startedAt.UnixMilli() {
			return
		}

		body := strings.TrimSpace(evt.Content.AsMessage().Body)
		var reply string

		switch {
		case body == "!ping":
			reply = "pong"
		case strings.HasPrefix(body, "!echo"):
			reply = strings.TrimSpace(strings.TrimPrefix(body, "!echo"))
			if reply == "" {
				reply = "…echo what?"
			}
		case isDirect(ctx, client, evt.RoomID):
			reply = fmt.Sprintf("you said: %s", body)
		default:
			return
		}

		if _, err := client.SendMessageEvent(ctx, evt.RoomID, event.EventMessage,
			&event.MessageEventContent{MsgType: event.MsgNotice, Body: reply}); err != nil {
			log.Printf("warn: could not reply in %s: %v", evt.RoomID, err)
		}
	})

	log.Printf("syncing")
	if err := client.SyncWithContext(ctx); err != nil && ctx.Err() == nil {
		log.Fatalf("sync: %v", err)
	}
}

// isDirect reports whether a room has exactly two joined members — the
// cheap definition of "a DM", and the one that matches what a person
// means when they open a one-to-one chat with the bot.
func isDirect(ctx context.Context, client *mautrix.Client, roomID id.RoomID) bool {
	members, err := client.JoinedMembers(ctx, roomID)
	if err != nil {
		return false
	}
	return len(members.Joined) == 2
}
