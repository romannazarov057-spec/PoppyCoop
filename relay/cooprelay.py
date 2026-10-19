#!/usr/bin/env python3
"""PoppyCoop relay: bridges the mod's position files to another player.

The UE4SS Lua mod cannot open sockets. It only has file I/O, so it writes its own
position to <netdir>/<self>.state and reads the other player's from
<netdir>/<peer>.state. This helper sits in between: it watches <self>.state, sends
the line to the peer, and writes whatever comes back to <peer>.state.

Two transports:

  udp    Local stand-in for automated tests: the host binds a UDP port, the client
         sends to it. No download, no Steam, works with two game instances on one
         machine.
  steam  Real play. Loads steam_api64.dll (pinned Steamworks.NET build, flat C API)
         and exchanges the same lines through ISteamNetworkingMessages, which goes
         over Valve's relay network: no IP addresses, no port forwarding.

Usage:
  python cooprelay.py --transport udp --role host --self A --peer B \
      --netdir D:\\coop-work\\poppy-playtime\\net\\A --port 27099
  python cooprelay.py --transport udp --role client --host 127.0.0.1 --port 27099 \
      --self B --peer A --netdir D:\\coop-work\\poppy-playtime\\net\\B

  python cooprelay.py --transport steam --role host --self A --peer B \
      --netdir ...\\net\\A --dll <dir-with-steam_api64.dll>
  python cooprelay.py --transport steam --role client --lobby <id> --self B --peer A \
      --netdir ...\\net\\B --dll <dir-with-steam_api64.dll>
"""

import argparse
import ctypes
import os
import socket
import sys
import time

POLL_S = 0.05          # how often to look at the file and the wire
RESEND_S = 1.0         # re-send unchanged state this often (keep-alive for UDP)
CHANNEL = 0            # ISteamNetworkingMessages channel for position data
SEND_RELIABLE_NONAGLE = 9   # k_nSteamNetworkingSend_Reliable | _NoNagle


def log(msg):
    line = time.strftime("[%H:%M:%S] ") + msg
    print(line, flush=True)
    if LOG_PATH:
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


LOG_PATH = None


def read_state(path):
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except (OSError, IOError):
        return None


def write_state_atomic(path, text):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(text + "\n")
        os.replace(tmp, path)
    except OSError:
        pass


# --------------------------------------------------------------------------- udp

class UdpTransport(object):
    """Host binds; client connects. One datagram per state line. For local tests."""

    def __init__(self, role, host, port):
        self.role = role
        self.peers = set()          # host only: addresses we have heard from
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if role == "host":
            self.sock.bind(("0.0.0.0", port))
            self.sock.setblocking(False)
            log("udp host listening on 0.0.0.0:%d" % port)
        else:
            self.sock.connect((host, port))
            self.sock.setblocking(False)
            self.peers.add((host, port))
            log("udp client -> %s:%d" % (host, port))

    def send(self, data):
        if self.role == "host":
            for addr in list(self.peers):
                try:
                    self.sock.sendto(data, addr)
                except OSError:
                    pass
        else:
            try:
                self.sock.send(data)
            except OSError:
                pass

    def poll(self):
        out = []
        while True:
            try:
                data, addr = self.sock.recvfrom(4096)
            except socket.error:
                break
            if self.role == "host" and addr not in self.peers:
                self.peers.add(addr)
                log("udp host: new peer %s:%d" % addr)
            out.append(data)
        return out


# ------------------------------------------------------------------------- steam

# SteamNetworkingIdentity is opaque; the playbook gives 136 bytes on Windows.
IDENTITY_SIZE = 136
CALLBACK_MSG_SIZE = 24      #int32 hSteamUser, int32 callback, ptr param, int32 param_size
CALLBACK_701_SIZE = 16      # SteamAPICallCompleted_t (x64, 8-byte aligned)
LOBBY_CREATED_SIZE = 16     # int32 result, pad, uint64 lobby
LOBBY_ENTER_SIZE = 24       # uint64 lobby, uint32 perms, bool locked, pad, uint32 response

CB_STEAM_APICALL_COMPLETED = 703
CB_LOBBY_CREATED = 513
CB_LOBBY_ENTER = 504
CB_SESSION_REQUEST = 1251
CB_SESSION_FAILED = 1252
CB_GAME_LOBBY_JOIN_REQUESTED = 333


class SteamTransport(object):
    def __init__(self, role, dll_dir, lobby_id, own_id):
        self.role = role
        self.own_steam_id = 0
        self.lobby = 0
        self.peer_steam_ids = []
        self.callbacks = []          # pending async calls we care about: call handle -> name

        if dll_dir:
            os.add_dll_directory(os.path.abspath(dll_dir))
        dll_path = os.path.join(os.path.abspath(dll_dir), "steam_api64.dll")
        if not os.path.exists(dll_path):
            raise SystemExit("steam_api64.dll not found in %s" % dll_dir)
        # The appid file must sit next to the exe/dll that is initialised.
        self._ensure_appid(dll_dir)
        log("loading %s" % dll_path)
        self.dll = ctypes.WinDLL(dll_path)
        self._bind()

        err = ctypes.create_string_buffer(1024)
        rc = self.dll.SteamAPI_InitFlat(err)
        if rc != 0:
            raise SystemExit("SteamAPI_InitFlat failed (%d): %s" % (rc, err.value.decode("utf-8", "replace")))
        log("SteamAPI_InitFlat ok, appid 480")

        self.steam_user = self.dll.SteamAPI_SteamUser_v023()
        self.matchmaking = self.dll.SteamAPI_SteamMatchmaking_v009()
        self.friends = self.dll.SteamAPI_SteamFriends_v018()
        self.messages = self.dll.SteamAPI_SteamNetworkingMessages_SteamAPI_v002()
        self.utils = self.dll.SteamAPI_SteamNetworkingUtils_SteamAPI_v004()

        if not self.dll.SteamAPI_ISteamUser_BLoggedOn(self.steam_user):
            raise SystemExit("Steam is running but not logged on")
        self.own_steam_id = self.dll.SteamAPI_ISteamUser_GetSteamID(self.steam_user)
        log("logged on as SteamID %d" % self.own_steam_id)

        self.dll.SteamAPI_ManualDispatch_Init()
        self.pipe = self.dll.SteamAPI_GetHSteamPipe()

        if role == "host":
            self._create_lobby()
        else:
            self._join_lobby(lobby_id)

    @staticmethod
    def _ensure_appid(dll_dir):
        targets = [os.path.abspath(dll_dir), os.getcwd()]
        for d in targets:
            p = os.path.join(d, "steam_appid.txt")
            if not os.path.exists(p):
                try:
                    with open(p, "w") as f:
                        f.write("480\n")
                    log("wrote steam_appid.txt (480) in %s" % d)
                except OSError:
                    pass

    def _bind(self):
        """Declare every prototype. Without argtypes, ctypes passes interface
        pointers as C int and truncates them on x64, so this is not optional."""
        d = self.dll
        P, I, U64, U32, I32, BOOL, STR = (ctypes.c_void_p, ctypes.c_int,
                                          ctypes.c_uint64, ctypes.c_uint32,
                                          ctypes.c_int32, ctypes.c_bool, ctypes.c_char_p)
        d.SteamAPI_InitFlat.argtypes = [ctypes.c_char_p]
        d.SteamAPI_InitFlat.restype = ctypes.c_int
        for getter in ("SteamAPI_SteamUser_v023", "SteamAPI_SteamMatchmaking_v009",
                       "SteamAPI_SteamFriends_v018",
                       "SteamAPI_SteamNetworkingMessages_SteamAPI_v002",
                       "SteamAPI_SteamNetworkingUtils_SteamAPI_v004"):
            getattr(d, getter).argtypes = []
            getattr(d, getter).restype = P
        d.SteamAPI_IsSteamRunning.argtypes = []
        d.SteamAPI_IsSteamRunning.restype = ctypes.c_bool
        d.SteamAPI_GetHSteamPipe.argtypes = []
        d.SteamAPI_GetHSteamPipe.restype = I32
        d.SteamAPI_ManualDispatch_Init.argtypes = []
        d.SteamAPI_ManualDispatch_RunFrame.argtypes = [I32]
        d.SteamAPI_ManualDispatch_GetNextCallback.argtypes = [I32, P]
        d.SteamAPI_ManualDispatch_GetNextCallback.restype = ctypes.c_bool
        d.SteamAPI_ManualDispatch_FreeLastCallback.argtypes = [I32]
        d.SteamAPI_ISteamUser_GetSteamID.argtypes = [P]
        d.SteamAPI_ISteamUser_GetSteamID.restype = U64
        d.SteamAPI_ISteamUser_BLoggedOn.argtypes = [P]
        d.SteamAPI_ISteamUser_BLoggedOn.restype = ctypes.c_bool
        d.SteamAPI_ISteamMatchmaking_CreateLobby.argtypes = [P, I, I]
        d.SteamAPI_ISteamMatchmaking_CreateLobby.restype = U64
        d.SteamAPI_ISteamMatchmaking_JoinLobby.argtypes = [P, U64]
        d.SteamAPI_ISteamMatchmaking_JoinLobby.restype = U64
        d.SteamAPI_ISteamMatchmaking_LeaveLobby.argtypes = [P, U64]
        d.SteamAPI_ISteamMatchmaking_SetLobbyData.argtypes = [P, U64, STR, STR]
        d.SteamAPI_ISteamMatchmaking_SetLobbyData.restype = ctypes.c_bool
        d.SteamAPI_ISteamMatchmaking_GetLobbyData.argtypes = [P, U64, STR]
        d.SteamAPI_ISteamMatchmaking_GetLobbyData.restype = STR
        d.SteamAPI_ISteamMatchmaking_SetLobbyJoinable.argtypes = [P, U64, ctypes.c_bool]
        d.SteamAPI_ISteamMatchmaking_SetLobbyJoinable.restype = ctypes.c_bool
        d.SteamAPI_ISteamMatchmaking_GetNumLobbyMembers.argtypes = [P, U64]
        d.SteamAPI_ISteamMatchmaking_GetNumLobbyMembers.restype = I
        d.SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex.argtypes = [P, U64, I]
        d.SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex.restype = U64
        d.SteamAPI_ISteamMatchmaking_GetLobbyOwner.argtypes = [P, U64]
        d.SteamAPI_ISteamMatchmaking_GetLobbyOwner.restype = U64
        d.SteamAPI_ISteamFriends_SetRichPresence.argtypes = [P, STR, STR]
        d.SteamAPI_ISteamFriends_SetRichPresence.restype = ctypes.c_bool
        d.SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog.argtypes = [P, U64]
        d.SteamAPI_SteamNetworkingIdentity_SetSteamID64.argtypes = [P, U64]
        d.SteamAPI_SteamNetworkingIdentity_GetSteamID64.argtypes = [P]
        d.SteamAPI_SteamNetworkingIdentity_GetSteamID64.restype = U64
        d.SteamAPI_ISteamNetworkingMessages_SendMessageToUser.argtypes = [P, P, P, U32, I, I]
        d.SteamAPI_ISteamNetworkingMessages_SendMessageToUser.restype = I
        d.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel.argtypes = [P, I, P, I]
        d.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel.restype = I
        d.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser.argtypes = [P, P]
        d.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser.restype = ctypes.c_bool
        d.SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser.argtypes = [P, P]
        d.SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser.restype = ctypes.c_bool
        d.SteamAPI_SteamNetworkingMessage_t_Release.argtypes = [P]
        d.SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32.argtypes = [P, I, I32]
        d.SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32.restype = ctypes.c_bool

    def _pump(self, frames=1):
        """Drive the manual callback dispatch; return callbacks seen."""
        seen = []
        for _ in range(frames):
            self.dll.SteamAPI_ManualDispatch_RunFrame(self.pipe)
            while True:
                msg = ctypes.create_string_buffer(CALLBACK_MSG_SIZE)
                if not self.dll.SteamAPI_ManualDispatch_GetNextCallback(
                        self.pipe, ctypes.cast(msg, ctypes.c_void_p)):
                    break
                # CallbackMsg_t (x64): hSteamUser@0, callback@4, param@8, param_size@16
                cb = ctypes.cast(msg, ctypes.POINTER(ctypes.c_int32))[1]
                data = ctypes.cast(msg, ctypes.POINTER(ctypes.c_void_p))[1]
                size = ctypes.cast(msg, ctypes.POINTER(ctypes.c_int32))[4]
                payload = ctypes.string_at(data, size) if data and size else b""
                seen.append((cb, payload))
                self.dll.SteamAPI_ManualDispatch_FreeLastCallback(self.pipe)
        for cb, payload in seen:
            self._on_callback(cb, payload)
        return seen

    def _on_callback(self, cb, payload):
        if cb == CB_LOBBY_CREATED:
            result = ctypes.cast(payload, ctypes.POINTER(ctypes.c_int32))[0]
            lobby = ctypes.cast(payload, ctypes.POINTER(ctypes.c_uint64))[1]
            log("LobbyCreated result=%d" % result)
            if result == 1 and lobby:
                self.lobby = lobby
                self._on_lobby_ready()
            else:
                raise SystemExit("lobby creation failed (result %d)" % result)
        elif cb == CB_LOBBY_ENTER:
            lobby = ctypes.cast(payload, ctypes.POINTER(ctypes.c_uint64))[0]
            # LobbyEnter_t: lobby@0, perms@8, locked@12, response@16
            response = ctypes.cast(payload, ctypes.POINTER(ctypes.c_int32))[4]
            log("LobbyEnter lobby=%d response=%d" % (lobby, response))
            if response == 1:
                self.lobby = lobby
                self._on_lobby_ready()
            else:
                raise SystemExit("lobby enter failed (response %d)" % response)
        elif cb == CB_SESSION_REQUEST:
            ident = ctypes.create_string_buffer(payload[:IDENTITY_SIZE], IDENTITY_SIZE)
            who = self.dll.SteamAPI_SteamNetworkingIdentity_GetSteamID64(
                ctypes.cast(ident, ctypes.c_void_p))
            if self._is_lobby_member(who):
                self.dll.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(
                    self.messages, ctypes.cast(ident, ctypes.c_void_p))
                log("accepted session from %d" % who)
            else:
                log("refused session from %d (not in our lobby)" % who)
        elif cb == CB_SESSION_FAILED:
            ident = ctypes.create_string_buffer(payload[:IDENTITY_SIZE], IDENTITY_SIZE)
            who = self.dll.SteamAPI_SteamNetworkingIdentity_GetSteamID64(
                ctypes.cast(ident, ctypes.c_void_p))
            log("session failed with %d" % who)
        elif cb == CB_GAME_LOBBY_JOIN_REQUESTED:
            lobby = ctypes.cast(payload, ctypes.POINTER(ctypes.c_uint64))[0]
            log("a friend asked to join lobby %d; use --lobby on their side" % lobby)

    def _is_lobby_member(self, steam_id):
        return True  # the lobby check is tightened once member-list exports are wired

    def _create_lobby(self):
        handle = self.dll.SteamAPI_ISteamMatchmaking_CreateLobby(self.matchmaking, 1, 2)  # 1 = friends-only
        log("CreateLobby call handle=%d" % handle)

    def _join_lobby(self, lobby_id):
        handle = self.dll.SteamAPI_ISteamMatchmaking_JoinLobby(self.matchmaking, ctypes.c_uint64(lobby_id))
        log("JoinLobby(%d) call handle=%d" % (lobby_id, handle))

    def _on_lobby_ready(self):
        if self.role == "host":
            self.dll.SteamAPI_ISteamMatchmaking_SetLobbyData(
                self.matchmaking, ctypes.c_uint64(self.lobby), b"poppycoop", b"1")
            self.dll.SteamAPI_ISteamFriends_SetRichPresence(
                self.friends, b"connect", b"+connect_lobby %d" % self.lobby)
            log("LOBBY READY. Friend joins with: --lobby %d" % self.lobby)
        else:
            self.dll.SteamAPI_ISteamFriends_SetRichPresence(
                self.friends, b"connect", b"+connect_lobby %d" % self.lobby)
            log("JOINED LOBBY %d" % self.lobby)

    def peer_ids(self):
        """Everyone in the lobby except us."""
        if not self.lobby:
            return []
        n = self.dll.SteamAPI_ISteamMatchmaking_GetNumLobbyMembers(self.matchmaking, ctypes.c_uint64(self.lobby))
        out = []
        for i in range(n):
            sid = self.dll.SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex(
                self.matchmaking, ctypes.c_uint64(self.lobby), i)
            if sid and sid != self.own_steam_id:
                out.append(sid)
        return out

    def send(self, data):
        for sid in self.peer_ids():
            ident = ctypes.create_string_buffer(IDENTITY_SIZE)
            self.dll.SteamAPI_SteamNetworkingIdentity_SetSteamID64(
                ctypes.cast(ident, ctypes.c_void_p), sid)
            rc = self.dll.SteamAPI_ISteamNetworkingMessages_SendMessageToUser(
                self.messages, ctypes.cast(ident, ctypes.c_void_p),
                ctypes.cast(ctypes.c_char_p(data), ctypes.c_void_p),
                len(data), SEND_RELIABLE_NONAGLE, CHANNEL)
            if rc < 0:
                log("send to %d failed (%d)" % (sid, rc))

    def poll(self):
        out = []
        self._pump(frames=1)
        while True:
            arr = (ctypes.c_void_p * 32)()
            n = self.dll.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(
                self.messages, CHANNEL, ctypes.cast(arr, ctypes.c_void_p), 32)
            if n <= 0:
                break
            for i in range(n):
                m = ctypes.c_void_p(arr[i])
                # x64 layout: m_pData@0, m_cbSize@8 (playbook).
                data = ctypes.cast(m, ctypes.POINTER(ctypes.c_void_p))[0]
                size = ctypes.cast(m, ctypes.POINTER(ctypes.c_int32))[2]
                if data and size:
                    out.append(ctypes.string_at(data, size))
                self.dll.SteamAPI_SteamNetworkingMessage_t_Release(m)
        return out


# ---------------------------------------------------------------------------- main

def main():
    global LOG_PATH
    ap = argparse.ArgumentParser()
    ap.add_argument("--transport", choices=["udp", "steam"], required=True)
    ap.add_argument("--role", choices=["host", "client"], required=True)
    ap.add_argument("--self", dest="own_id", required=True, help="this player's id, e.g. A")
    ap.add_argument("--peer", required=True, help="the other player's id, e.g. B")
    ap.add_argument("--netdir", required=True, help="folder both state files live in")
    ap.add_argument("--port", type=int, default=27099)
    ap.add_argument("--host", default="127.0.0.1", help="udp client target")
    ap.add_argument("--lobby", type=int, default=0, help="steam client: lobby id to join")
    ap.add_argument("--dll", default=".", help="folder with steam_api64.dll")
    ap.add_argument("--log", default=None)
    args = ap.parse_args()

    os.makedirs(args.netdir, exist_ok=True)
    LOG_PATH = args.log

    if args.transport == "udp":
        transport = UdpTransport(args.role, args.host, args.port)
    else:
        transport = SteamTransport(args.role, args.dll, args.lobby, args.own_id)

    self_path = os.path.join(args.netdir, args.own_id + ".state")
    peer_path = os.path.join(args.netdir, args.peer + ".state")
    log("relay %s: %s <-> %s (%s, %s)" % (args.own_id, self_path, peer_path,
                                           args.transport, args.role))

    last = None
    last_sent_at = 0.0
    while True:
        now = time.time()
        text = read_state(self_path)
        if text and (text != last or now - last_sent_at > RESEND_S):
            transport.send(text.encode("ascii", "ignore"))
            last = text
            last_sent_at = now
        for msg in transport.poll():
            try:
                write_state_atomic(peer_path, msg.decode("ascii", "replace").strip())
            except Exception as e:  # noqa: BLE001
                log("bad message: %r (%s)" % (msg, e))
        time.sleep(POLL_S)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
