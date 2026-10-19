import ctypes, sys, os

NEEDED = [
    "SteamAPI_InitFlat", "SteamAPI_IsSteamRunning", "SteamAPI_GetHSteamPipe",
    "SteamAPI_ManualDispatch_Init", "SteamAPI_ManualDispatch_RunFrame",
    "SteamAPI_ManualDispatch_GetNextCallback", "SteamAPI_ManualDispatch_FreeLastCallback",
    "SteamAPI_ManualDispatch_GetAPICallResult",
    "SteamAPI_SteamUser_v023", "SteamAPI_SteamMatchmaking_v009", "SteamAPI_SteamFriends_v018",
    "SteamAPI_SteamNetworkingMessages_SteamAPI_v002", "SteamAPI_SteamNetworkingUtils_SteamAPI_v004",
    "SteamAPI_ISteamUser_GetSteamID", "SteamAPI_ISteamUser_BLoggedOn",
    "SteamAPI_ISteamMatchmaking_CreateLobby", "SteamAPI_ISteamMatchmaking_JoinLobby",
    "SteamAPI_ISteamMatchmaking_LeaveLobby", "SteamAPI_ISteamMatchmaking_SetLobbyData",
    "SteamAPI_ISteamMatchmaking_GetLobbyData", "SteamAPI_ISteamMatchmaking_SetLobbyJoinable",
    "SteamAPI_ISteamFriends_SetRichPresence",
    "SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog",
    "SteamAPI_SteamNetworkingIdentity_SetSteamID64", "SteamAPI_SteamNetworkingIdentity_GetSteamID64",
    "SteamAPI_ISteamNetworkingMessages_SendMessageToUser",
    "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel",
    "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser",
    "SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser",
    "SteamAPI_SteamNetworkingMessage_t_Release",
    "SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32",
]

for path in sys.argv[1:]:
    print("=== %s (%d bytes) ===" % (path, os.path.getsize(path)))
    try:
        dll = ctypes.WinDLL(path)
    except OSError as e:
        print("  load failed:", e)
        continue
    missing = []
    for n in NEEDED:
        try:
            getattr(dll, n)
        except AttributeError:
            missing.append(n)
    print("  exports present: %d/%d" % (len(NEEDED) - len(missing), len(NEEDED)))
    if missing:
        print("  MISSING:", ", ".join(missing))
